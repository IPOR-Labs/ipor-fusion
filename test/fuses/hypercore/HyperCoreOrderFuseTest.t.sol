// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";

import {
    HyperCoreOrderFuse,
    HyperCoreOrderFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreOrderFuse.sol";
import {HyperCoreBalanceFuse} from "../../../contracts/fuses/hypercore/HyperCoreBalanceFuse.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";
import {HyperCorePendingLib} from "../../../contracts/fuses/hypercore/lib/HyperCorePendingLib.sol";

import {HyperCoreTestHelper, HyperCoreMockUsdc} from "./HyperCoreTestHelper.sol";
import {HyperCoreMockState} from "./mocks/MockHyperCorePrecompiles.sol";
import {MockCoreWriter} from "./mocks/MockCoreWriter.sol";

import {PlasmaVaultHelper} from "../../test_helpers/PlasmaVaultHelper.sol";
import {IporFusionAccessManagerHelper} from "../../test_helpers/IporFusionAccessManagerHelper.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";

/// @dev Minimal IPriceOracleMiddleware test double whose QUOTE_CURRENCY matches the real deployed
///      PriceOracleMiddleware (0x...0348) so it is accepted as a drop-in replacement.
contract HyperCoreTestPriceOracle is IPriceOracleMiddleware {
    mapping(address => uint256) public prices;
    mapping(address => uint256) public priceDecimals;

    function setAssetPriceWithDecimals(address asset_, uint256 price_, uint256 decimals_) external {
        prices[asset_] = price_;
        priceDecimals[asset_] = decimals_;
    }

    function getAssetPrice(address asset_) external view returns (uint256 assetPrice, uint256 decimals) {
        assetPrice = prices[asset_];
        decimals = priceDecimals[asset_];
    }

    function getAssetsPrices(
        address[] calldata assets_
    ) external view returns (uint256[] memory assetPrices, uint256[] memory decimalsList) {
        assetPrices = new uint256[](assets_.length);
        decimalsList = new uint256[](assets_.length);
        for (uint256 i; i < assets_.length; ++i) {
            assetPrices[i] = prices[assets_[i]];
            decimalsList[i] = priceDecimals[assets_[i]];
        }
    }

    function getSourceOfAssetPrice(address) external pure returns (address) {
        return address(0);
    }

    function setAssetsPricesSources(address[] calldata, address[] calldata) external {}

    // solhint-disable-next-line func-name-mixedcase
    function QUOTE_CURRENCY() external pure returns (address) {
        return address(0x0000000000000000000000000000000000000348);
    }

    // solhint-disable-next-line func-name-mixedcase
    function QUOTE_CURRENCY_DECIMALS() external pure returns (uint256) {
        return 18;
    }
}

contract HyperCoreOrderFuseTest is Test {
    uint256 private constant MARKET_ID = 55;
    uint32 private constant ASSET = 0; // mock default: szDecimals = 5 => lot = 1000
    bytes32 private constant PENDING_SLOT = 0xff3841d45e92b4b113213ebf16e5e18527d87d1b739008d460c4a8565edaf200;

    HyperCoreMockState private core;
    MockCoreWriter private coreWriter;
    PlasmaVault private vault;
    HyperCoreMockUsdc private usdc;
    HyperCoreTestPriceOracle private oracle;
    HyperCoreOrderFuse private orderFuse;
    HyperCoreBalanceFuse private balanceFuse;

    function setUp() public {
        core = HyperCoreTestHelper.etchPrecompiles(vm);
        coreWriter = HyperCoreTestHelper.etchCoreWriter(vm);

        vm.startPrank(TestAddresses.ATOMIST);
        address withdrawManager;
        (vault, withdrawManager, usdc, ) = HyperCoreTestHelper.deployVaultWithHyperCoreMarket(TestAddresses.ATOMIST);
        IporFusionAccessManager accessManager = PlasmaVaultHelper.accessManagerOf(vault);
        IporFusionAccessManagerHelper.setupInitRoles(
            accessManager,
            vault,
            withdrawManager,
            address(new RewardsClaimManager(address(accessManager), address(vault)))
        );
        vm.stopPrank();

        oracle = new HyperCoreTestPriceOracle();
        vm.prank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(vault)).setPriceOracleMiddleware(address(oracle));
        oracle.setAssetPriceWithDecimals(address(usdc), 1e8, 8);

        orderFuse = new HyperCoreOrderFuse(MARKET_ID);
        balanceFuse = new HyperCoreBalanceFuse(MARKET_ID);

        vm.startPrank(TestAddresses.FUSE_MANAGER);
        address[] memory fuses = new address[](1);
        fuses[0] = address(orderFuse);
        PlasmaVaultHelper.addFusesToVault(vault, fuses);
        PlasmaVaultHelper.addBalanceFusesToVault(vault, MARKET_ID, address(balanceFuse));
        vm.stopPrank();

        core.setCoreUserExists(address(vault), true);
        _grantMarket(10_000, false);
    }

    function testEnterTimingSendsExactPayloadWithoutPendingRecord() public {
        core.setL1BlockNumber(100);
        vm.expectEmit(true, true, true, true, address(vault));
        emit HyperCoreOrderFuse.HyperCoreOrderFuseEnter(address(orderFuse), ASSET, true, 100e8, 1000, false, 2, 1);
        _execute(true, 100e8, 1000, false, 2, 1);

        bytes memory expected = _expectPayload(
            HyperCoreLib.ACTION_LIMIT_ORDER,
            abi.encode(ASSET, true, uint64(100e8), uint64(1000), false, uint8(2), uint128(1))
        );
        assertEq(coreWriter.lastAction(), expected);

        (uint64 pendingUntil, , , uint8 actionClass, , , , ) = _readPending();
        assertEq(pendingUntil, 0);
        assertEq(actionClass, uint8(HyperCorePendingLib.ActionClass.None));
        // Only the persistent mini-gate field is set (slot 9 of the pending struct).
        assertEq(
            uint64(uint256(vm.load(address(vault), bytes32(uint256(PENDING_SLOT) + 9)))),
            uint64(100)
        );
    }

    /// @dev IL-8543: the reserved `SettlementMode` / `WindowOrderSeconds` keys are decoded but ignored, with any
    ///      value (including ones the removed validation rejected): orders are always TIMING.
    function testEnterIgnoresLegacySettlementKeysWithAnyValue() public {
        core.setL1BlockNumber(100);
        vm.prank(TestAddresses.FUSE_MANAGER);
        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = HyperCoreSubstrateLib.encodePerpMarket(ASSET, 10_000, false);
        substrates[1] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.SettlementMode, 2);
        substrates[2] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.WindowOrderSeconds, 0);
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);
        _execute(true, 100e8, 1000, false, 2, 1);
        (uint64 pendingUntil, , , uint8 actionClass, , , , ) = _readPending();
        assertEq(pendingUntil, 0, "no pending record even when the legacy mode says REPORTED");
        assertEq(actionClass, uint8(HyperCorePendingLib.ActionClass.None));

        core.setL1BlockNumber(101);
        substrates[1] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.SettlementMode, 257);
        vm.prank(TestAddresses.FUSE_MANAGER);
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);
        _execute(true, 100e8, 1000, false, 2, 2);
    }

    function testEnterRevertsWhenAccountNotActivated() public {
        core.setCoreUserExists(address(vault), false);
        vm.expectRevert(HyperCoreOrderFuse.HyperCoreOrderFuseAccountNotActivated.selector);
        _execute(true, 100e8, 1000, false, 2, 1);
    }

    function testEnterRevertsWhenMarketNotGranted() public {
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreOrderFuse.HyperCoreOrderFuseMarketNotGranted.selector, uint32(5))
        );
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(orderFuse),
            data: abi.encodeWithSignature(
                "enter((uint32,bool,uint64,uint64,bool,uint8,uint128))",
                HyperCoreOrderFuseEnterData({
                    asset: 5,
                    isBuy: true,
                    limitPx: 100e8,
                    sz: 1000,
                    reduceOnly: false,
                    tif: 2,
                    cloid: 1
                })
            )
        });
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);
    }

    function testEnterRevertsOnInvalidTif() public {
        vm.expectRevert(abi.encodeWithSelector(HyperCoreOrderFuse.HyperCoreOrderFuseInvalidTif.selector, uint8(4)));
        _execute(true, 100e8, 1000, false, 4, 1);
    }

    function testEnterRevertsOnZeroCloid() public {
        vm.expectRevert(HyperCoreOrderFuse.HyperCoreOrderFuseCloidRequired.selector);
        _execute(true, 100e8, 1000, false, 2, 0);
    }

    function testEnterRevertsOnZeroSize() public {
        vm.expectRevert(HyperCoreOrderFuse.HyperCoreOrderFuseZeroAmount.selector);
        _execute(true, 100e8, 0, false, 2, 1);
    }

    function testEnterRevertsOnZeroPrice() public {
        vm.expectRevert(HyperCoreOrderFuse.HyperCoreOrderFuseZeroAmount.selector);
        _execute(true, 0, 1000, false, 2, 1);
    }

    function testEnterRevertsOnInvalidLot() public {
        // lot = 10^(8-5) = 1000; 1500 is not a multiple.
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreOrderFuse.HyperCoreOrderFuseInvalidLot.selector, uint64(1500), uint64(1000))
        );
        _execute(true, 100e8, 1500, false, 2, 1);
    }

    function testEnterRevertsWhenExceedingMaxNotional() public {
        _grantMarket(10, false); // cap = $0.00001
        vm.expectRevert(
            abi.encodeWithSelector(
                HyperCoreOrderFuse.HyperCoreOrderFuseExceedsMaxNotional.selector,
                uint256(1000),
                uint88(10)
            )
        );
        _execute(true, 100e8, 1000, false, 2, 1);
    }

    function testEnterRevertsWhenReduceOnlyRequiredButNotSet() public {
        _grantMarket(10_000, true);
        vm.expectRevert(HyperCoreOrderFuse.HyperCoreOrderFuseReduceOnlyRequired.selector);
        _execute(true, 100e8, 1000, false, 2, 1);
    }

    function testSecondOrderInSameExecuteReverts() public {
        core.setL1BlockNumber(100);
        _assertSecondOrderInSameExecuteReverts(
            abi.encodeWithSelector(HyperCorePendingLib.HyperCoreOrderRateLimited.selector, uint64(100))
        );
    }

    function _assertSecondOrderInSameExecuteReverts(bytes memory expectedRevert_) private {        FuseAction[] memory actions = new FuseAction[](2);
        actions[0] = FuseAction({
            fuse: address(orderFuse),
            data: abi.encodeWithSignature(
                "enter((uint32,bool,uint64,uint64,bool,uint8,uint128))",
                HyperCoreOrderFuseEnterData({
                    asset: ASSET,
                    isBuy: true,
                    limitPx: 100e8,
                    sz: 1000,
                    reduceOnly: false,
                    tif: 2,
                    cloid: 1
                })
            )
        });
        actions[1] = FuseAction({
            fuse: address(orderFuse),
            data: abi.encodeWithSignature(
                "enter((uint32,bool,uint64,uint64,bool,uint8,uint128))",
                HyperCoreOrderFuseEnterData({
                    asset: ASSET,
                    isBuy: true,
                    limitPx: 100e8,
                    sz: 1000,
                    reduceOnly: false,
                    tif: 2,
                    cloid: 2
                })
            )
        });

        vm.expectRevert(expectedRevert_);
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);
    }

    /// @dev audit HC-01 / IL-8536: a sell limit is only a floor, so a crossing sell fills at the (higher) bid.
    ///      The cap must be checked against max(limitPx, markPx), not `sz * limitPx`.
    function testSellRevertsWhenMarkNotionalExceedsCapEvenThoughLimitNotionalFits() public {
        _grantMarket(1_000e6, false);
        core.setMarkPx(ASSET, 400); // $40 at szDecimals 5
        vm.expectRevert(
            abi.encodeWithSelector(
                HyperCoreOrderFuse.HyperCoreOrderFuseExceedsMaxNotional.selector,
                uint256(40_000e6),
                uint88(1_000e6)
            )
        );
        _execute(false, 1e8, 1_000e8, false, 3, 1);
    }

    function testSellRevertDoesNotCallCoreWriter() public {
        _grantMarket(1_000e6, false);
        core.setMarkPx(ASSET, 400);
        vm.expectRevert();
        _execute(false, 1e8, 1_000e8, false, 3, 1);
        assertEq(coreWriter.callCount(), 0);
    }

    function testSellWithinCapAtMarkSendsUnchangedLimitPayload() public {
        _grantMarket(40_000e6, false);
        core.setMarkPx(ASSET, 400);
        _execute(false, 1e8, 1_000e8, false, 3, 1);
        assertEq(
            coreWriter.lastAction(),
            _expectPayload(
                HyperCoreLib.ACTION_LIMIT_ORDER,
                abi.encode(ASSET, false, uint64(1e8), uint64(1_000e8), false, uint8(3), uint128(1))
            )
        );
    }

    function testSellUsesLimitPriceWhenAboveMarkAtCap() public {
        _grantMarket(50_000e6, false);
        core.setMarkPx(ASSET, 400);
        _execute(false, 50e8, 1_000e8, false, 3, 1);
        assertEq(coreWriter.callCount(), 1);
    }

    function testSellUsesLimitPriceWhenAboveMarkRevertsAboveCap() public {
        _grantMarket(49_999e6, false);
        core.setMarkPx(ASSET, 400);
        vm.expectRevert(
            abi.encodeWithSelector(
                HyperCoreOrderFuse.HyperCoreOrderFuseExceedsMaxNotional.selector,
                uint256(50_000e6),
                uint88(49_999e6)
            )
        );
        _execute(false, 50e8, 1_000e8, false, 3, 1);
    }

    function testBuyIgnoresMarkPrice() public {
        _grantMarket(1_000e6, false);
        core.setMarkPx(ASSET, 400);
        _execute(true, 1e8, 1_000e8, false, 3, 1);
        assertEq(coreWriter.callCount(), 1);
    }

    function testBuyDoesNotReadMarkPrice() public {
        _grantMarket(1_000e6, false);
        core.setFail(HyperCoreLib.MARK_PX_PRECOMPILE, true);
        _execute(true, 1e8, 1_000e8, false, 3, 1);
        assertEq(coreWriter.callCount(), 1);
    }

    function testSellFailsClosedWhenMarkPrecompileFails() public {
        _grantMarket(1_000e6, false);
        core.setFail(HyperCoreLib.MARK_PX_PRECOMPILE, true);
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreLib.HyperCorePrecompileFailed.selector, HyperCoreLib.MARK_PX_PRECOMPILE)
        );
        _execute(false, 1e8, 1_000e8, false, 3, 1);
    }

    function testSellRevertsWhenMarkPriceIsZero() public {
        _grantMarket(1_000e6, false);
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreOrderFuse.HyperCoreOrderFuseMarkPriceUnavailable.selector, uint32(0))
        );
        _execute(false, 1e8, 1_000e8, false, 3, 1);
    }

    function testReduceOnlySellAlsoAdmittedAtMark() public {
        _grantMarket(1_000e6, false);
        core.setMarkPx(ASSET, 400);
        vm.expectRevert(
            abi.encodeWithSelector(
                HyperCoreOrderFuse.HyperCoreOrderFuseExceedsMaxNotional.selector,
                uint256(40_000e6),
                uint88(1_000e6)
            )
        );
        _execute(false, 1e8, 1_000e8, true, 3, 1);
    }

    function testSellMarkScalingFollowsSzDecimals0() public {
        _assertSellMarkScaling(0, 40_000_000, 40_000e6);
    }

    function testSellMarkScalingFollowsSzDecimals2() public {
        _assertSellMarkScaling(2, 400_000, 40_000e6);
    }

    /// @dev At szDecimals 8 the raw scale has 6 - 8 < 0 decimals: raw 1 means $100 (a $40 mark is not representable).
    function testSellMarkScalingFollowsSzDecimals8() public {
        _assertSellMarkScaling(8, 1, 100_000e6);
    }

    /// @dev `rawMark_` is in the raw HyperCore scale `price * 10^(6 - szDecimals)`; sells 1_000 units at limit $1.
    function _assertSellMarkScaling(uint8 szDecimals_, uint64 rawMark_, uint256 expectedNotionalUsd6_) private {
        uint32 asset = 1;
        core.setPerpAssetInfo(
            asset,
            HyperCoreMockState.PerpAssetInfo({
                coin: "SCALE",
                marginTableId: 0,
                szDecimals: szDecimals_,
                maxLeverage: 10,
                onlyIsolated: false
            })
        );
        core.setMarkPx(asset, rawMark_);
        _grantAsset(asset, 1_000e6, false);
        vm.expectRevert(
            abi.encodeWithSelector(
                HyperCoreOrderFuse.HyperCoreOrderFuseExceedsMaxNotional.selector,
                expectedNotionalUsd6_,
                uint88(1_000e6)
            )
        );
        _executeAsset(asset, false, 1e8, 1_000e8, false, 3, 1);
    }

    function _grantMarket(uint88 maxNotionalUsd6_, bool reduceOnlyRequired_) private {
        _grantAsset(ASSET, maxNotionalUsd6_, reduceOnlyRequired_);
    }

    function _grantAsset(uint32 asset_, uint88 maxNotionalUsd6_, bool reduceOnlyRequired_) private {
        vm.prank(TestAddresses.FUSE_MANAGER);
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = HyperCoreSubstrateLib.encodePerpMarket(asset_, maxNotionalUsd6_, reduceOnlyRequired_);
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);
    }

    function _execute(bool isBuy_, uint64 limitPx_, uint64 sz_, bool reduceOnly_, uint8 tif_, uint128 cloid_) private {
        _executeAsset(ASSET, isBuy_, limitPx_, sz_, reduceOnly_, tif_, cloid_);
    }

    function _executeAsset(
        uint32 asset_,
        bool isBuy_,
        uint64 limitPx_,
        uint64 sz_,
        bool reduceOnly_,
        uint8 tif_,
        uint128 cloid_
    ) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(orderFuse),
            data: abi.encodeWithSignature(
                "enter((uint32,bool,uint64,uint64,bool,uint8,uint128))",
                HyperCoreOrderFuseEnterData({
                    asset: asset_,
                    isBuy: isBuy_,
                    limitPx: limitPx_,
                    sz: sz_,
                    reduceOnly: reduceOnly_,
                    tif: tif_,
                    cloid: cloid_
                })
            )
        });
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);
    }

    function _expectPayload(uint24 actionId_, bytes memory fields_) private pure returns (bytes memory) {
        return abi.encodePacked(bytes1(uint8(1)), bytes3(actionId_), fields_);
    }

    function _readPending()
        private
        view
        returns (
            uint64 pendingUntil,
            uint64 enqueuedL1Block,
            uint64 enqueuedEvmBlock,
            uint8 actionClass,
            uint8 settlementMode,
            uint24 actionId,
            bytes32 payloadHash,
            uint256 cachedValueWad
        )
    {
        bytes32 slot0 = vm.load(address(vault), PENDING_SLOT);
        pendingUntil = uint64(uint256(slot0));
        enqueuedL1Block = uint64(uint256(slot0) >> 64);
        enqueuedEvmBlock = uint64(uint256(slot0) >> 128);
        actionClass = uint8(uint256(slot0) >> 192);
        settlementMode = uint8(uint256(slot0) >> 200);

        bytes32 slot1 = vm.load(address(vault), bytes32(uint256(PENDING_SLOT) + 1));
        actionId = uint24(uint256(slot1) >> 64);

        payloadHash = vm.load(address(vault), bytes32(uint256(PENDING_SLOT) + 2));

        cachedValueWad = uint256(vm.load(address(vault), bytes32(uint256(PENDING_SLOT) + 4)));
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";

import {
    HyperCoreCancelFuse,
    HyperCoreCancelFuseCancelByOidData,
    HyperCoreCancelFuseCancelByCloidData
} from "../../../contracts/fuses/hypercore/HyperCoreCancelFuse.sol";
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

contract HyperCoreCancelFuseTest is Test {
    uint256 private constant MARKET_ID = 55;
    uint32 private constant ASSET = 0;
    bytes32 private constant PENDING_SLOT = 0xff3841d45e92b4b113213ebf16e5e18527d87d1b739008d460c4a8565edaf200;

    HyperCoreMockState private core;
    MockCoreWriter private coreWriter;
    PlasmaVault private vault;
    HyperCoreMockUsdc private usdc;
    HyperCoreTestPriceOracle private oracle;
    HyperCoreCancelFuse private cancelFuse;
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

        cancelFuse = new HyperCoreCancelFuse(MARKET_ID);
        balanceFuse = new HyperCoreBalanceFuse(MARKET_ID);

        vm.startPrank(TestAddresses.FUSE_MANAGER);
        address[] memory fuses = new address[](1);
        fuses[0] = address(cancelFuse);
        PlasmaVaultHelper.addFusesToVault(vault, fuses);
        PlasmaVaultHelper.addBalanceFusesToVault(vault, MARKET_ID, address(balanceFuse));
        vm.stopPrank();

        core.setCoreUserExists(address(vault), true);
        _grantMarket();
    }

    function testEnterCancelByOidTimingSendsPayloadWithoutPendingRecordOrGate() public {
        core.setL1BlockNumber(100);
        vm.expectEmit(true, true, true, true, address(vault));
        emit HyperCoreCancelFuse.HyperCoreCancelFuseCancelByOid(address(cancelFuse), ASSET, 42);
        _executeCancelByOid(ASSET, 42);

        bytes memory expected = _expectPayload(HyperCoreLib.ACTION_CANCEL_BY_OID, abi.encode(ASSET, uint64(42)));
        assertEq(coreWriter.lastAction(), expected);
        _assertNoRecordAndNoGate();
    }

    function testEnterCancelByCloidTimingSendsPayloadWithoutPendingRecordOrGate() public {
        core.setL1BlockNumber(100);
        vm.expectEmit(true, true, true, true, address(vault));
        emit HyperCoreCancelFuse.HyperCoreCancelFuseCancelByCloid(address(cancelFuse), ASSET, 7);
        _executeCancelByCloid(ASSET, 7);

        bytes memory expected = _expectPayload(HyperCoreLib.ACTION_CANCEL_BY_CLOID, abi.encode(ASSET, uint128(7)));
        assertEq(coreWriter.lastAction(), expected);
        _assertNoRecordAndNoGate();
    }

    /// @dev TIMING cancels are not rate limited: two cancels in the same Core block both go through.
    function testTimingCancelsAreNotRateLimited() public {
        core.setL1BlockNumber(100);
        _executeCancelByOid(ASSET, 1);
        _executeCancelByOid(ASSET, 2);
        _assertNoRecordAndNoGate();
    }

    function _assertNoRecordAndNoGate() private view {
        (uint64 pendingUntil, , , uint8 actionClass, , , , ) = _readPending();
        assertEq(pendingUntil, 0);
        assertEq(actionClass, uint8(HyperCorePendingLib.ActionClass.None));
        // lastOrderL1Block (slot 9 of the pending struct) is untouched by cancels.
        assertEq(uint256(vm.load(address(vault), bytes32(uint256(PENDING_SLOT) + 9))), 0);
    }

    function testEnterCancelByOidRevertsOnZeroOid() public {
        vm.expectRevert(HyperCoreCancelFuse.HyperCoreCancelFuseOidRequired.selector);
        _executeCancelByOid(ASSET, 0);
    }

    function testEnterCancelByCloidRevertsOnZeroCloid() public {
        vm.expectRevert(HyperCoreCancelFuse.HyperCoreCancelFuseCloidRequired.selector);
        _executeCancelByCloid(ASSET, 0);
    }

    function testEnterRevertsWhenAccountNotActivated() public {
        core.setCoreUserExists(address(vault), false);
        vm.expectRevert(HyperCoreCancelFuse.HyperCoreCancelFuseAccountNotActivated.selector);
        _executeCancelByOid(ASSET, 1);
    }

    function testEnterRevertsWhenMarketNotGranted() public {
        vm.expectRevert(abi.encodeWithSelector(HyperCoreCancelFuse.HyperCoreCancelFuseMarketNotGranted.selector, uint32(9)));
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(cancelFuse),
            data: abi.encodeWithSignature(
                "enterCancelByOid((uint32,uint64))", HyperCoreCancelFuseCancelByOidData({asset: 9, oid: 1})
            )
        });
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);
    }

    /// @dev IL-8543: the reserved `SettlementMode` / `WindowOrderSeconds` keys are ignored, with any value
    ///      (including values the removed validation rejected): cancels still send and create no record.
    function testCancelIgnoresLegacySettlementKeysWithAnyValue() public {
        vm.prank(TestAddresses.FUSE_MANAGER);
        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = HyperCoreSubstrateLib.encodePerpMarket(ASSET, 10_000, false);
        substrates[1] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.SettlementMode, 257);
        substrates[2] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.WindowOrderSeconds, 0);
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);

        core.setL1BlockNumber(100);
        _executeCancelByOid(ASSET, 1);
        assertEq(coreWriter.lastAction(), _expectPayload(HyperCoreLib.ACTION_CANCEL_BY_OID, abi.encode(ASSET, uint64(1))));
        _assertNoRecordAndNoGate();
    }

    /// @dev Cancels create no pending record, so several cancels can run in one `execute`.
    function testTwoCancelsInSameExecuteSucceedAndCreateNoRecord() public {
        core.setL1BlockNumber(100);
        FuseAction[] memory actions = new FuseAction[](2);
        actions[0] = FuseAction({
            fuse: address(cancelFuse),
            data: abi.encodeWithSignature(
                "enterCancelByOid((uint32,uint64))", HyperCoreCancelFuseCancelByOidData({asset: ASSET, oid: 1})
            )
        });
        actions[1] = FuseAction({
            fuse: address(cancelFuse),
            data: abi.encodeWithSignature(
                "enterCancelByOid((uint32,uint64))", HyperCoreCancelFuseCancelByOidData({asset: ASSET, oid: 2})
            )
        });
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);
        _assertNoRecordAndNoGate();
    }

    function _grantMarket() private {
        vm.prank(TestAddresses.FUSE_MANAGER);
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = HyperCoreSubstrateLib.encodePerpMarket(ASSET, 10_000, false);
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);
    }

    function _executeCancelByOid(uint32 asset_, uint64 oid_) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(cancelFuse),
            data: abi.encodeWithSignature(
                "enterCancelByOid((uint32,uint64))", HyperCoreCancelFuseCancelByOidData({asset: asset_, oid: oid_})
            )
        });
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);
    }

    function _executeCancelByCloid(uint32 asset_, uint128 cloid_) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(cancelFuse),
            data: abi.encodeWithSignature(
                "enterCancelByCloid((uint32,uint128))", HyperCoreCancelFuseCancelByCloidData({asset: asset_, cloid: cloid_})
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

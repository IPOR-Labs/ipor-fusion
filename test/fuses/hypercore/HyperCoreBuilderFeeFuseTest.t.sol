// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";

import {
    HyperCoreBuilderFeeFuse,
    HyperCoreBuilderFeeFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreBuilderFeeFuse.sol";
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

contract HyperCoreBuilderFeeFuseTest is Test {
    uint256 private constant MARKET_ID = 55;
    bytes32 private constant PENDING_SLOT = 0xff3841d45e92b4b113213ebf16e5e18527d87d1b739008d460c4a8565edaf200;

    HyperCoreMockState private core;
    MockCoreWriter private coreWriter;
    PlasmaVault private vault;
    HyperCoreMockUsdc private usdc;
    HyperCoreTestPriceOracle private oracle;
    HyperCoreBuilderFeeFuse private builderFeeFuse;
    HyperCoreBalanceFuse private balanceFuse;
    address private builder;

    function setUp() public {
        core = HyperCoreTestHelper.etchPrecompiles(vm);
        coreWriter = HyperCoreTestHelper.etchCoreWriter(vm);
        builder = makeAddr("builder");

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

        builderFeeFuse = new HyperCoreBuilderFeeFuse(MARKET_ID);
        balanceFuse = new HyperCoreBalanceFuse(MARKET_ID);

        vm.startPrank(TestAddresses.FUSE_MANAGER);
        address[] memory fuses = new address[](1);
        fuses[0] = address(builderFeeFuse);
        PlasmaVaultHelper.addFusesToVault(vault, fuses);
        PlasmaVaultHelper.addBalanceFusesToVault(vault, MARKET_ID, address(balanceFuse));
        vm.stopPrank();

        core.setCoreUserExists(address(vault), true);
        _grantBuilder(builder, 100);
    }

    function testEnterSendsExactPayloadAndEnqueuesTransferClassPending() public {
        vm.expectEmit(true, true, true, true, address(vault));
        emit HyperCoreBuilderFeeFuse.HyperCoreBuilderFeeFuseEnter(address(builderFeeFuse), builder, 50);
        _execute(builder, 50);

        bytes memory expected = _expectPayload(HyperCoreLib.ACTION_APPROVE_BUILDER_FEE, abi.encode(uint64(50), builder));
        assertEq(coreWriter.lastAction(), expected);

        (uint64 pendingUntil, , , uint8 actionClass, , uint24 actionId, bytes32 payloadHash, uint256 cachedValueWad) =
            _readPending();
        assertTrue(pendingUntil > 0);
        assertEq(actionClass, uint8(HyperCorePendingLib.ActionClass.Transfer));
        assertEq(actionId, HyperCoreLib.ACTION_APPROVE_BUILDER_FEE);
        assertEq(payloadHash, keccak256(HyperCoreLib.encodeApproveBuilderFee(50, builder)));
        assertEq(cachedValueWad, 0, "builder fee approval is NAV-neutral: C = S = 0 here");
    }

    /// @dev IL-8958 (C-037): with non-zero Core equity the enqueued snapshot is the live value `S`, so the stored
    ///      market value is kept while the approval is pending and after the window.
    function testEnterCachesNonZeroLiveValueAndKeepsStoredValue() public {
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = HyperCoreSubstrateLib.encodeBuilder(builder, 100);
        substrates[1] = HyperCoreSubstrateLib.encodeSpotToken(0, address(usdc));
        vm.prank(TestAddresses.FUSE_MANAGER);
        PlasmaVaultGovernance(address(vault)).grantMarketSubstrates(MARKET_ID, substrates);

        // 1,000 USDC on Core spot (weiDecimals = 8), priced 1:1 by the oracle.
        core.setSpotBalance(address(vault), 0, HyperCoreMockState.SpotBalance({total: 1_000e8, hold: 0, entryNtl: 0}));
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = MARKET_ID;
        vm.prank(TestAddresses.ATOMIST);
        vault.updateMarketsBalances(marketIds);
        uint256 storedBefore = vault.totalAssetsInMarket(MARKET_ID);
        assertEq(storedBefore, 1_000e6, "precondition: stored market value is the live Core equity");

        _execute(builder, 50);

        (, , , , , , , uint256 cachedValueWad) = _readPending();
        assertEq(cachedValueWad, 1_000e18, "enqueued snapshot equals the live value S");
        assertEq(vault.totalAssetsInMarket(MARKET_ID), storedBefore, "stored value kept by execute");

        vm.warp(block.timestamp + 3);
        core.setL1BlockNumber(core.getL1BlockNumber() + 10);
        vm.prank(TestAddresses.ATOMIST);
        vault.updateMarketsBalances(marketIds);
        assertEq(vault.totalAssetsInMarket(MARKET_ID), storedBefore, "refresh after the window yields the same value");
    }

    function testEnterRevertsWhenAccountNotActivated() public {
        core.setCoreUserExists(address(vault), false);
        vm.expectRevert(HyperCoreBuilderFeeFuse.HyperCoreBuilderFeeFuseAccountNotActivated.selector);
        _execute(builder, 50);
    }

    function testEnterRevertsWhenBuilderNotGranted() public {
        address ungranted = makeAddr("ungranted");
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreBuilderFeeFuse.HyperCoreBuilderFeeFuseBuilderNotGranted.selector, ungranted)
        );
        _execute(ungranted, 50);
    }

    function testEnterRevertsWhenExceedingGrantedMaxRate() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                HyperCoreBuilderFeeFuse.HyperCoreBuilderFeeFuseExceedsMaxRate.selector, uint64(150), uint64(100)
            )
        );
        _execute(builder, 150);
    }

    function testEnterRevertsOnZeroWindowConfig() public {
        vm.prank(TestAddresses.FUSE_MANAGER);
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = HyperCoreSubstrateLib.encodeBuilder(builder, 100);
        substrates[1] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.WindowTransferSeconds, 0);
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);

        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreBuilderFeeFuse.HyperCoreBuilderFeeFuseInvalidWindow.selector, uint240(0))
        );
        _execute(builder, 50);
    }

    function testEnterRevertsOnWindowOverflowingUint64() public {
        uint240 overflowingWindow = uint240(type(uint64).max) + 1;
        vm.prank(TestAddresses.FUSE_MANAGER);
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = HyperCoreSubstrateLib.encodeBuilder(builder, 100);
        substrates[1] = HyperCoreSubstrateLib.encodeConfig(
            HyperCoreSubstrateLib.ConfigKey.WindowTransferSeconds, overflowingWindow
        );
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);

        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreBuilderFeeFuse.HyperCoreBuilderFeeFuseInvalidWindow.selector, overflowingWindow)
        );
        _execute(builder, 50);
    }

    function testSecondBuilderFeeActionInSameExecuteReverts() public {
        FuseAction[] memory actions = new FuseAction[](2);
        actions[0] = FuseAction({
            fuse: address(builderFeeFuse),
            data: abi.encodeWithSignature(
                "enter((address,uint64))", HyperCoreBuilderFeeFuseEnterData({builder: builder, maxFeeRateDecibps: 10})
            )
        });
        actions[1] = FuseAction({
            fuse: address(builderFeeFuse),
            data: abi.encodeWithSignature(
                "enter((address,uint64))", HyperCoreBuilderFeeFuseEnterData({builder: builder, maxFeeRateDecibps: 10})
            )
        });

        vm.expectRevert(
            abi.encodeWithSelector(HyperCorePendingLib.HyperCoreActionPending.selector, uint64(block.timestamp + 2))
        );
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);
    }

    function _grantBuilder(address builder_, uint64 maxRate_) private {
        vm.prank(TestAddresses.FUSE_MANAGER);
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = HyperCoreSubstrateLib.encodeBuilder(builder_, maxRate_);
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, substrates);
    }

    function _execute(address builder_, uint64 maxFeeRateDecibps_) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(builderFeeFuse),
            data: abi.encodeWithSignature(
                "enter((address,uint64))",
                HyperCoreBuilderFeeFuseEnterData({builder: builder_, maxFeeRateDecibps: maxFeeRateDecibps_})
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

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
import {
    HyperCoreCancelFuse,
    HyperCoreCancelFuseCancelByOidData,
    HyperCoreCancelFuseCancelByCloidData
} from "../../../contracts/fuses/hypercore/HyperCoreCancelFuse.sol";
import {HyperCoreBalanceFuse} from "../../../contracts/fuses/hypercore/HyperCoreBalanceFuse.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {HyperCoreAssetIdLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreAssetIdLib.sol";
import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";
import {HyperCoreTestHelper, HyperCoreMockUsdc} from "./HyperCoreTestHelper.sol";
import {HyperCoreMockState} from "./mocks/MockHyperCorePrecompiles.sol";
import {MockCoreWriter} from "./mocks/MockCoreWriter.sol";
import {PlasmaVaultHelper} from "../../test_helpers/PlasmaVaultHelper.sol";
import {IporFusionAccessManagerHelper} from "../../test_helpers/IporFusionAccessManagerHelper.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";

contract HyperCoreHip3OrderCancelOracle is IPriceOracleMiddleware {
    function getAssetPrice(address) external pure returns (uint256 assetPrice, uint256 decimals) {
        return (1e8, 8);
    }

    function getAssetsPrices(
        address[] calldata assets
    ) external pure returns (uint256[] memory assetPrices, uint256[] memory decimalsList) {
        assetPrices = new uint256[](assets.length);
        decimalsList = new uint256[](assets.length);
        for (uint256 i; i < assets.length; ++i) {
            assetPrices[i] = 1e8;
            decimalsList[i] = 8;
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

/// @dev Production fuse executes through PlasmaVault delegatecall as in the native order suite.
contract HyperCoreHip3OrderCancelTest is Test {
    uint256 private constant MARKET_ID = 55;
    bytes32 private constant PENDING_SLOT = 0xff3841d45e92b4b113213ebf16e5e18527d87d1b739008d460c4a8565edaf200;
    HyperCoreMockState private core;
    MockCoreWriter private coreWriter;
    PlasmaVault private vault;
    HyperCoreMockUsdc private usdc;
    HyperCoreHip3OrderCancelOracle private oracle;
    HyperCoreOrderFuse private orderFuse;
    HyperCoreBalanceFuse private balanceFuse;
    HyperCoreCancelFuse private cancelFuse;

    function setUp() public {
        vm.chainId(999);
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
        oracle = new HyperCoreHip3OrderCancelOracle();
        vm.prank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(vault)).setPriceOracleMiddleware(address(oracle));
        orderFuse = new HyperCoreOrderFuse(MARKET_ID);
        balanceFuse = new HyperCoreBalanceFuse(MARKET_ID);
        cancelFuse = new HyperCoreCancelFuse(MARKET_ID);
        vm.startPrank(TestAddresses.FUSE_MANAGER);
        address[] memory fuses = new address[](2);
        fuses[0] = address(orderFuse);
        fuses[1] = address(cancelFuse);
        PlasmaVaultHelper.addFusesToVault(vault, fuses);
        PlasmaVaultHelper.addBalanceFusesToVault(vault, MARKET_ID, address(balanceFuse));
        vm.stopPrank();
        core.setCoreUserExists(address(vault), true);
    }

    function testHip3OrdersKeepActionAssetAndReadLocalMetadata() public {
        _grantSingleHip3(110002, 2);
        _setAssetInfo(10002, 6);
        _execute(110002, 100e8, 100, 1); // valid at local szDecimals 6; default metadata would reject lot 100
        assertEq(coreWriter.lastAction(), _payload(110002, 100e8, 100, 1));
    }

    function testParaOrderUsesReadIndexAndFractionalLotMetadata() public {
        _grantSingleHip3(180000, 256);
        _setAssetInfo(80000, 6);
        _execute(180000, 100e8, 100, 2); // valid at szDecimals 6, invalid at default szDecimals 5
        assertEq(coreWriter.lastAction(), _payload(180000, 100e8, 100, 2));
    }

    function testIoOrderUsesReadIndexAndLocalMetadata() public {
        _grantSingleHip3(200001, 1024);
        _setAssetInfo(100001, 6);
        _execute(200001, 100e8, 100, 3);
        assertEq(coreWriter.lastAction(), _payload(200001, 100e8, 100, 3));
    }

    function testIoOrderUsesReadIndexAndRejectsWrongLotMetadata() public {
        _grantSingleHip3(200001, 1024);
        _setAssetInfo(100001, 4);
        vm.expectRevert(
            abi.encodeWithSelector(
                HyperCoreOrderFuse.HyperCoreOrderFuseInvalidLot.selector,
                uint64(1000),
                uint64(10000)
            )
        );
        _execute(200001, 100e8, 1000, 3);
        assertEq(coreWriter.lastAction(), bytes(""));
    }

    function testNativeOrderWithHip3AndNativeGrantsRequiresSingleMarket() public {
        _grantMany(0, 110002, 2);
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreOrderFuse.HyperCoreOrderFuseSingleMarketRequired.selector, uint256(2))
        );
        _execute(0, 100e8, 1000, 4);
        assertEq(coreWriter.lastAction(), bytes(""));
    }

    function testDuplicateHip3GrantsAreCountedAndRejected() public {
        _grantMany(110002, 110002, 2);
        _setAssetInfo(10002, 5);
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreOrderFuse.HyperCoreOrderFuseSingleMarketRequired.selector, uint256(2))
        );
        _execute(110002, 100e8, 1000, 5);
        assertEq(coreWriter.lastAction(), bytes(""));
    }

    function testMultipleHip3MarketsAreRejected() public {
        _grantMany(110002, 110003, 2);
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreOrderFuse.HyperCoreOrderFuseSingleMarketRequired.selector, uint256(2))
        );
        _execute(110002, 100e8, 1000, 14);
        assertEq(coreWriter.lastAction(), bytes(""));
    }

    function testNativeOnlyMultipleMarketsRemainAllowed() public {
        _grantMany(0, 1, 0);
        _execute(0, 100e8, 1000, 6);
        assertEq(coreWriter.lastAction(), _payload(0, 100e8, 1000, 6));
    }

    function testRejectsInvalidAssetFamiliesAndUnsupportedDex() public {
        _grantMany(10000, 99999, type(uint240).max);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreAssetIdLib.HyperCoreInvalidPerpAsset.selector, uint32(10000)));
        _execute(10000, 100e8, 1000, 7);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreAssetIdLib.HyperCoreInvalidPerpAsset.selector, uint32(99999)));
        _execute(99999, 100e8, 1000, 8);
        _grantMany(10001, 100000000, type(uint240).max);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreAssetIdLib.HyperCoreInvalidPerpAsset.selector, uint32(10001)));
        _execute(10001, 100e8, 1000, 9);
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreAssetIdLib.HyperCoreInvalidPerpAsset.selector, uint32(100000000))
        );
        _execute(100000000, 100e8, 1000, 10);
    }

    function testUnsupportedDexIsRejected() public {
        _grantSingleHip3(120000, 4);
        _setAssetInfo(20000, 5);
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreOrderFuse.HyperCoreOrderFuseUnsupportedPerpDex.selector, uint32(2))
        );
        _execute(120000, 100e8, 1000, 10);
    }

    function testSupportedDexMustBeConfigured() public {
        _grantSingleHip3(110002, 0);
        _setAssetInfo(10002, 5);
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreOrderFuse.HyperCoreOrderFusePerpDexNotConfigured.selector, uint32(1))
        );
        _execute(110002, 100e8, 1000, 11);
    }

    function testConfiguredDexRequiresHyperEvmChain() public {
        _grantSingleHip3(110002, 2);
        _setAssetInfo(10002, 5);
        vm.chainId(998);
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreOrderFuse.HyperCoreOrderFuseUnsupportedPerpDex.selector, uint32(1))
        );
        _execute(110002, 100e8, 1000, 11);
    }

    function testValuationFailurePreventsCoreWriterCallOrPendingState() public {
        _grantSingleHip3(110002, 2);
        _setAssetInfo(10002, 5);
        core.setAccountMarginSummaryFail(1, true);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreLib.HyperCorePrecompileFailed.selector, address(0x80f)));
        _execute(110002, 100e8, 1000, 12);
        assertEq(coreWriter.lastAction(), bytes(""));
        assertEq(vm.load(address(vault), PENDING_SLOT), bytes32(0));
    }

    function testHip3SellIsAdmittedAtMarkReadThroughReadIndex() public {
        _grantSingleHip3(110002, 2);
        _setAssetInfo(10002, 3);
        core.setMarkPx(10002, 223970); // $223.97 at szDecimals 3
        vm.expectRevert(
            abi.encodeWithSelector(
                HyperCoreOrderFuse.HyperCoreOrderFuseExceedsMaxNotional.selector,
                uint256(2_239_700_000),
                uint88(1_000_000_000)
            )
        );
        _executeSell(110002, 1e8, 10e8, 1);
    }

    function testHip3SellWithinCapSucceeds() public {
        _grantSingleHip3(110002, 2);
        _setAssetInfo(10002, 3);
        core.setMarkPx(10002, 223970);
        _executeSell(110002, 1e8, 1e8, 1);
        assertEq(
            coreWriter.lastAction(),
            abi.encodePacked(
                bytes1(uint8(1)),
                bytes3(uint24(1)),
                abi.encode(uint32(110002), false, uint64(1e8), uint64(1e8), false, uint8(2), uint128(1))
            )
        );
    }

    function testCancelByOidPreservesXyzActionAssetAndCreatesNoPendingRecord() public {
        _grantSingleHip3(110002, 2);
        _executeCancelByOid(110002, 42);

        bytes memory expected = _expectPayload(
            HyperCoreLib.ACTION_CANCEL_BY_OID,
            abi.encode(uint32(110002), uint64(42))
        );
        assertEq(coreWriter.lastAction(), expected);
        assertEq(vm.load(address(vault), PENDING_SLOT), bytes32(0), "cancels create no pending record");
    }

    function testCancelByCloidPreservesXyzActionAssetAndCreatesNoPendingRecord() public {
        _grantSingleHip3(110002, 2);
        _executeCancelByCloid(110002, 77);

        bytes memory expected = _expectPayload(
            HyperCoreLib.ACTION_CANCEL_BY_CLOID,
            abi.encode(uint32(110002), uint128(77))
        );
        assertEq(coreWriter.lastAction(), expected);
        assertEq(vm.load(address(vault), PENDING_SLOT), bytes32(0), "cancels create no pending record");
    }

    function testCancelByOidPreservesParaActionAsset() public {
        _grantSingleHip3(180000, 256);
        _executeCancelByOid(180000, 88);
        bytes memory expected = _expectPayload(
            HyperCoreLib.ACTION_CANCEL_BY_OID,
            abi.encode(uint32(180000), uint64(88))
        );
        assertEq(coreWriter.lastAction(), expected);
        assertEq(vm.load(address(vault), PENDING_SLOT), bytes32(0), "cancels create no pending record");
    }

    function testCancelByCloidPreservesIoActionAsset() public {
        _grantSingleHip3(200001, 1024);
        _executeCancelByCloid(200001, 99);
        bytes memory expected = _expectPayload(
            HyperCoreLib.ACTION_CANCEL_BY_CLOID,
            abi.encode(uint32(200001), uint128(99))
        );
        assertEq(coreWriter.lastAction(), expected);
        assertEq(vm.load(address(vault), PENDING_SLOT), bytes32(0), "cancels create no pending record");
    }

    function testCancelRejectsInvalidGrantedAssetFamily() public {
        _grantSingleHip3(10000, type(uint240).max);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreAssetIdLib.HyperCoreInvalidPerpAsset.selector, uint32(10000)));
        _executeCancelByOid(10000, 1);
        assertEq(coreWriter.lastAction(), bytes(""));
    }

    function testCancelRejectsUnconditionallyUnsupportedDex() public {
        _grantSingleHip3(120000, 4);
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreCancelFuse.HyperCoreCancelFuseUnsupportedPerpDex.selector, uint32(2))
        );
        _executeCancelByOid(120000, 1);
        assertEq(coreWriter.lastAction(), bytes(""));
    }

    function testCancelRejectsSupportedButUnconfiguredDex() public {
        _grantSingleHip3(110002, 0);
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreCancelFuse.HyperCoreCancelFusePerpDexNotConfigured.selector, uint32(1))
        );
        _executeCancelByOid(110002, 1);
        assertEq(coreWriter.lastAction(), bytes(""));
    }

    function testCancelRejectsHip3OnWrongChain() public {
        _grantSingleHip3(110002, 2);
        vm.chainId(998);
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreCancelFuse.HyperCoreCancelFuseUnsupportedPerpDex.selector, uint32(1))
        );
        _executeCancelByOid(110002, 1);
        assertEq(coreWriter.lastAction(), bytes(""));
    }

    function testCancelRejectsUnGrantedMarket() public {
        _grantMany(0, type(uint32).max, 0);
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreCancelFuse.HyperCoreCancelFuseMarketNotGranted.selector, uint32(110002))
        );
        _executeCancelByOid(110002, 1);
        assertEq(coreWriter.lastAction(), bytes(""));
    }

    function testCancelRemainsAvailableWithMultipleGrantedMarkets() public {
        _grantMany(110002, 180000, 258);
        _executeCancelByOid(180000, 123);
        assertEq(
            coreWriter.lastAction(),
            _expectPayload(HyperCoreLib.ACTION_CANCEL_BY_OID, abi.encode(uint32(180000), uint64(123)))
        );
    }

    function testCancelRejectsWhenDexBitClearedAndSucceedsWhenRestored() public {
        _grantSingleHip3(110002, 0);
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreCancelFuse.HyperCoreCancelFusePerpDexNotConfigured.selector, uint32(1))
        );
        _executeCancelByOid(110002, 321);
        assertEq(coreWriter.lastAction(), bytes(""));

        _grantSingleHip3(110002, 2);
        _executeCancelByOid(110002, 321);
        assertEq(
            coreWriter.lastAction(),
            _expectPayload(HyperCoreLib.ACTION_CANCEL_BY_OID, abi.encode(uint32(110002), uint64(321)))
        );
    }

    function _grantSingleHip3(uint32 asset, uint240 dexBitmap) private {
        _grantMany(asset, type(uint32).max, dexBitmap);
    }

    /// @dev IL-8534: valuation now reads the position of every granted market, so a granted HIP-3 market must
    ///      exist on Core (the mock reverts on unregistered read indices, as the chain does).
    function _ensureHip3Registered(uint32 asset) private {
        if (asset < 110_000 || asset >= 100_000_000) return;
        uint32 readIndex = asset - 100_000;
        if (!core.isHip3MarketRegistered(readIndex)) _setAssetInfo(readIndex, 2);
    }

    function _grantMany(uint32 first, uint32 second, uint240 dexBitmap) private {
        _ensureHip3Registered(first);
        if (second != type(uint32).max) _ensureHip3Registered(second);
        vm.prank(TestAddresses.FUSE_MANAGER);
        uint256 extra = second == type(uint32).max ? 0 : 1;
        uint256 configExtra = dexBitmap == type(uint240).max ? 0 : 1;
        uint256 firstConfig = 1 + extra;
        bytes32[] memory subs = new bytes32[](firstConfig + configExtra);
        subs[0] = HyperCoreSubstrateLib.encodePerpMarket(first, 1_000_000_000, false);
        if (extra == 1) subs[1] = HyperCoreSubstrateLib.encodePerpMarket(second, 1_000_000_000, false);
        if (configExtra == 1) {
            subs[firstConfig] = HyperCoreSubstrateLib.encodeConfig(
                HyperCoreSubstrateLib.ConfigKey.PerpDexIds,
                dexBitmap
            );
        }
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, subs);
    }

    function _setAssetInfo(uint32 readIndex, uint8 decimals_) private {
        core.setPerpAssetInfo(
            readIndex,
            HyperCoreMockState.PerpAssetInfo({
                coin: "HIP3",
                marginTableId: 0,
                szDecimals: decimals_,
                maxLeverage: 10,
                onlyIsolated: false
            })
        );
    }

    function _execute(uint32 asset, uint64 px, uint64 sz, uint128 cloid) private {
        _executeSide(asset, true, px, sz, cloid);
    }

    function _executeSell(uint32 asset, uint64 px, uint64 sz, uint128 cloid) private {
        _executeSide(asset, false, px, sz, cloid);
    }

    function _executeSide(uint32 asset, bool isBuy, uint64 px, uint64 sz, uint128 cloid) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(orderFuse),
            data: abi.encodeWithSignature(
                "enter((uint32,bool,uint64,uint64,bool,uint8,uint128))",
                HyperCoreOrderFuseEnterData(asset, isBuy, px, sz, false, 2, cloid)
            )
        });
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);
    }

    function _executeCancelByOid(uint32 asset, uint64 oid) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(cancelFuse),
            data: abi.encodeWithSignature(
                "enterCancelByOid((uint32,uint64))",
                HyperCoreCancelFuseCancelByOidData({asset: asset, oid: oid})
            )
        });
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);
    }

    function _executeCancelByCloid(uint32 asset, uint128 cloid) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(cancelFuse),
            data: abi.encodeWithSignature(
                "enterCancelByCloid((uint32,uint128))",
                HyperCoreCancelFuseCancelByCloidData({asset: asset, cloid: cloid})
            )
        });
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);
    }

    function _payload(uint32 asset, uint64 px, uint64 sz, uint128 cloid) private pure returns (bytes memory) {
        return
            abi.encodePacked(
                bytes1(uint8(1)),
                bytes3(uint24(1)),
                abi.encode(asset, true, px, sz, false, uint8(2), cloid)
            );
    }

    function _expectPayload(uint24 actionId, bytes memory fields) private pure returns (bytes memory) {
        return abi.encodePacked(bytes1(uint8(1)), bytes3(actionId), fields);
    }
}

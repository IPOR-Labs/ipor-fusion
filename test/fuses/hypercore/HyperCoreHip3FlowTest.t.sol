// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVault, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";

import {
    HyperCoreDepositFuse,
    HyperCoreDepositFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreDepositFuse.sol";
import {
    HyperCoreSendFuse,
    HyperCoreSendFuseSpotSendData,
    HyperCoreSendFuseSendAssetData
} from "../../../contracts/fuses/hypercore/HyperCoreSendFuse.sol";
import {
    HyperCoreOrderFuse,
    HyperCoreOrderFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreOrderFuse.sol";
import {
    HyperCoreCancelFuse,
    HyperCoreCancelFuseCancelByCloidData
} from "../../../contracts/fuses/hypercore/HyperCoreCancelFuse.sol";
import {HyperCoreBalanceFuse} from "../../../contracts/fuses/hypercore/HyperCoreBalanceFuse.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";
import {HyperCorePendingLib} from "../../../contracts/fuses/hypercore/lib/HyperCorePendingLib.sol";
import {
    HyperCorePendingActionPreHook
} from "../../../contracts/handlers/pre_hooks/pre_hooks/HyperCorePendingActionPreHook.sol";
import {
    HyperCoreCapitalFlowPreHook
} from "../../../contracts/handlers/pre_hooks/pre_hooks/HyperCoreCapitalFlowPreHook.sol";

import {HyperCoreTestHelper, HyperCoreMockUsdc} from "./HyperCoreTestHelper.sol";
import {HyperCoreMockState} from "./mocks/MockHyperCorePrecompiles.sol";
import {MockCoreWriter} from "./mocks/MockCoreWriter.sol";
import {MockCoreDepositWallet} from "./mocks/MockCoreDepositWallet.sol";
import {HyperCoreHip3RawFixtures} from "./fixtures/HyperCoreHip3RawFixtures.sol";

import {PlasmaVaultHelper} from "../../test_helpers/PlasmaVaultHelper.sol";
import {IporFusionAccessManagerHelper} from "../../test_helpers/IporFusionAccessManagerHelper.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";

/// @dev Fixed $1 (8-decimal) price for every asset queried; sufficient for this suite since USDC is
///      the only priced asset (underlying and the sole granted spot token).
contract HyperCoreHip3FlowOracle is IPriceOracleMiddleware {
    function getAssetPrice(address) external pure returns (uint256 assetPrice, uint256 decimals) {
        return (1e8, 8);
    }

    function getAssetsPrices(
        address[] calldata assets_
    ) external pure returns (uint256[] memory assetPrices, uint256[] memory decimalsList) {
        assetPrices = new uint256[](assets_.length);
        decimalsList = new uint256[](assets_.length);
        for (uint256 i; i < assets_.length; ++i) {
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

/// @title HyperCoreHip3FlowTest
/// @notice End-to-end HIP-3 flow through the real PlasmaVault, production fuses and the settlement
///         reporter. The test plays HyperCore: it changes the mock precompile state to simulate what
///         Core would do after each action, then settles/refreshes exactly the way production does.
contract HyperCoreHip3FlowTest is Test {
    uint256 private constant MARKET_ID = IporFusionMarkets.HYPERCORE;
    bytes32 private constant PENDING_SLOT = 0xff3841d45e92b4b113213ebf16e5e18527d87d1b739008d460c4a8565edaf200;

    // xyz:NVDA — dex 1, index 2: action asset 110002, read index 10002.
    uint32 private constant XYZ_ASSET = 110002;
    uint32 private constant XYZ_READ_INDEX = 10002;
    uint32 private constant XYZ_DEX = 1;
    uint240 private constant XYZ_DEX_BITMAP = 2; // bit 1 set


    // Mock position units: `szi` is in units of 10^-szDecimals (szDecimals = 3 for xyz:NVDA, from the
    // mainnet fixture below), `entryNtl` is USD with 6 decimals. Every order below buys sz = 1e8 (1.0
    // in the fuse's 1e8 scale) at limitPx = 100e8 ($100), i.e. notional $100 -> szi = 1.000 = 1000,
    // entryNtl = $100 = 100e6. A short position would use a negative szi.
    int64 private constant XYZ_POSITION_SZI = 1000;
    uint64 private constant XYZ_POSITION_ENTRY_NTL = 100e6;

    // Shared PnL-scenario baseline (cases 2, 4, 5, 6, 7): the vault already holds $1,000 collateral on
    // xyz before the order; a filled order then changes dex equity to collateral + PnL = $1,050.
    uint256 private constant BASE_COLLATERAL_USD6 = 1_000e6;
    uint256 private constant FILL_PNL_USD6 = 50e6;

    HyperCoreMockState private core;
    MockCoreWriter private coreWriter;
    PlasmaVault private vault;
    HyperCoreMockUsdc private usdc;
    IporFusionAccessManager private accessManager;
    HyperCoreHip3FlowOracle private oracle;

    HyperCoreDepositFuse private depositFuse;
    HyperCoreSendFuse private sendFuse;
    HyperCoreOrderFuse private orderFuse;
    HyperCoreCancelFuse private cancelFuse;
    HyperCoreBalanceFuse private balanceFuse;
    MockCoreDepositWallet private depositWallet;

    address private usdcSystemAddress;

    function setUp() public {
        vm.chainId(999);
        core = HyperCoreTestHelper.etchPrecompiles(vm);
        core.setL1BlockNumber(100);
        coreWriter = HyperCoreTestHelper.etchCoreWriter(vm);

        vm.startPrank(TestAddresses.ATOMIST);
        address withdrawManager;
        (vault, withdrawManager, usdc, ) = HyperCoreTestHelper.deployVaultWithHyperCoreMarket(TestAddresses.ATOMIST);
        accessManager = PlasmaVaultHelper.accessManagerOf(vault);
        IporFusionAccessManagerHelper.setupInitRoles(
            accessManager,
            vault,
            withdrawManager,
            address(new RewardsClaimManager(address(accessManager), address(vault)))
        );
        vm.stopPrank();

        oracle = new HyperCoreHip3FlowOracle();
        vm.prank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(vault)).setPriceOracleMiddleware(address(oracle));

        depositFuse = new HyperCoreDepositFuse(MARKET_ID);
        sendFuse = new HyperCoreSendFuse(MARKET_ID);
        orderFuse = new HyperCoreOrderFuse(MARKET_ID);
        cancelFuse = new HyperCoreCancelFuse(MARKET_ID);
        balanceFuse = new HyperCoreBalanceFuse(MARKET_ID);

        vm.startPrank(TestAddresses.FUSE_MANAGER);
        address[] memory fuses = new address[](4);
        fuses[0] = address(depositFuse);
        fuses[1] = address(sendFuse);
        fuses[2] = address(orderFuse);
        fuses[3] = address(cancelFuse);
        PlasmaVaultHelper.addFusesToVault(vault, fuses);
        PlasmaVaultHelper.addBalanceFusesToVault(vault, MARKET_ID, address(balanceFuse));
        vm.stopPrank();

        usdcSystemAddress = HyperCoreLib.systemAddress(HyperCoreLib.USDC_TOKEN);
        depositWallet = new MockCoreDepositWallet(address(usdc));
        core.setTokenInfo(
            HyperCoreLib.USDC_TOKEN,
            HyperCoreMockState.TokenInfo({
                name: "USDC",
                spots: new uint64[](0),
                deployerTradingFeeShare: 0,
                deployer: address(0),
                evmContract: address(depositWallet),
                szDecimals: 8,
                weiDecimals: 8,
                evmExtraWeiDecimals: -2
            })
        );

        _installHooks();
        _grantSubstrates(XYZ_DEX_BITMAP, true, false);
        _registerXyzNvdaFromFixture();

        usdc.mint(TestAddresses.USER, 1_000_000e6);
        vm.prank(TestAddresses.USER);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ---------------------------------------------------------------------
    // 1. Full flow, TIMING mode, NAV after every step.
    // ---------------------------------------------------------------------

    function testFullFlowTimingModeNavAfterEveryStep() public {
        // a. user deposits 1,000 USDC.
        vm.prank(TestAddresses.USER);
        vault.deposit(1_000e6, TestAddresses.USER);
        assertEq(vault.totalAssets(), 1_000e6, "a: totalAssets == deposit");
        assertEq(vault.totalAssetsInMarket(MARKET_ID), 0, "a: market 55 empty before any HyperCore action");

        // b. deposit fuse: EVM -> Core spot. Before this action: live Core value S = 0 (unactivated
        // account), in-transit credit A = $1000 (the full deposited amount). `PlasmaVault.execute()`
        // refreshes market 55 with every fuse action it runs, so the pending cache S + A is visible
        // immediately (HyperCoreDepositFuse.enter(): `cachedValueWad = S + creditValueWad`), and
        // totalAssets() is unchanged because the $1000 that just left the EVM balance is now counted
        // in the market-55 cache instead.
        _executeDeposit(1_000e6);
        assertEq(vault.totalAssetsInMarket(MARKET_ID), 1_000e6, "b (pre-settle): market == S + A == $1000");
        assertEq(vault.totalAssets(), 1_000e6, "b (pre-settle): totalAssets unchanged (EVM loss offset by market gain)");

        core.setCoreUserExists(address(vault), true);
        core.setSpotBalance(
            address(vault), HyperCoreLib.USDC_TOKEN, HyperCoreMockState.SpotBalance({total: 1_000e8, hold: 0, entryNtl: 0})
        );
        _settleAndRefresh();
        assertEq(vault.totalAssetsInMarket(MARKET_ID), 1_000e6, "b: market == $1000");
        assertEq(vault.totalAssets(), 1_000e6, "b: NAV unchanged");

        // c. send fuse action 13: spot -> xyz (self-send). Destination == vault, so
        // HyperCoreSendFuse._cachedValueWad caches the pre-move live value S unchanged: moving between
        // the vault's own Core balances never changes the cached value.
        _executeSendAsset(address(vault), HyperCoreLib.SPOT_DEX, XYZ_DEX, HyperCoreLib.USDC_TOKEN, 1_000e8);
        assertEq(
            coreWriter.lastAction(),
            HyperCoreLib.encodeSendAsset(address(vault), address(0), HyperCoreLib.SPOT_DEX, XYZ_DEX, HyperCoreLib.USDC_TOKEN, uint64(1_000e8)),
            "c: send-asset payload"
        );
        assertEq(vault.totalAssetsInMarket(MARKET_ID), 1_000e6, "c (pre-settle): market == S (self-move, unchanged)");
        assertEq(vault.totalAssets(), 1_000e6, "c (pre-settle): totalAssets unchanged");

        core.setSpotBalance(address(vault), HyperCoreLib.USDC_TOKEN, HyperCoreMockState.SpotBalance({total: 0, hold: 0, entryNtl: 0}));
        _setDexEquity(XYZ_DEX, int64(uint64(uint256(1_000e6))));
        _settleAndRefresh();
        assertEq(vault.totalAssetsInMarket(MARKET_ID), 1_000e6, "c: NAV unchanged after self-move");
        assertEq(vault.totalAssets(), 1_000e6, "c: totalAssets unchanged");

        // d. order fuse: IOC buy on the HIP-3 market.
        _executeOrder(XYZ_ASSET, true, 100e8, 1e8, false, HyperCoreLib.TIF_IOC, 1);
        (uint32 payloadAsset, , , , , , ) = _decodeOrderPayload(coreWriter.lastAction());
        assertEq(payloadAsset, XYZ_ASSET, "d: payload carries the action asset 110002");
        assertEq(vault.totalAssetsInMarket(MARKET_ID), 1_000e6, "d (pre-settle): market == S, unchanged by the order");
        core.setPosition(
            address(vault), XYZ_READ_INDEX,
            HyperCoreMockState.Position({szi: XYZ_POSITION_SZI, entryNtl: XYZ_POSITION_ENTRY_NTL, isolatedRawUsd: 0, leverage: 20, isIsolated: false})
        );
        // collateral only, no PnL yet -> accountValue unchanged.
        _setDexEquity(XYZ_DEX, int64(uint64(uint256(1_000e6))));
        _settleAndRefresh();
        assertEq(vault.totalAssetsInMarket(MARKET_ID), 1_000e6, "d: NAV unchanged after fill (no PnL yet)");
        assertEq(vault.totalAssets(), 1_000e6, "d: totalAssets unchanged");

        // e. price moves up: only the mock summary changes.
        _setDexEquity(XYZ_DEX, int64(uint64(uint256(1_050e6))));
        _refresh();
        assertEq(vault.totalAssetsInMarket(MARKET_ID), 1_050e6, "e: NAV up by exactly X = $50");
        assertEq(vault.totalAssets(), 1_050e6, "e: totalAssets up by exactly X = $50");

        // f. order fuse: reduce-only IOC sell closing the position.
        _executeOrder(XYZ_ASSET, false, 100e8, 1e8, true, HyperCoreLib.TIF_IOC, 2);
        assertEq(vault.totalAssetsInMarket(MARKET_ID), 1_050e6, "f (pre-settle): market == S, unchanged by the order");
        core.setPosition(
            address(vault), XYZ_READ_INDEX,
            HyperCoreMockState.Position({szi: 0, entryNtl: 0, isolatedRawUsd: 0, leverage: 20, isIsolated: false})
        );
        // collateral + realized PnL == the value just before closing.
        _setDexEquity(XYZ_DEX, int64(uint64(uint256(1_050e6))));
        _settleAndRefresh();
        assertEq(vault.totalAssetsInMarket(MARKET_ID), 1_050e6, "f: NAV equals previous ($1050)");
        assertEq(vault.totalAssets(), 1_050e6, "f: totalAssets equals previous ($1050)");

        // g. send fuse action 13: xyz -> spot for the full dex equity (self-send).
        _executeSendAsset(address(vault), XYZ_DEX, HyperCoreLib.SPOT_DEX, HyperCoreLib.USDC_TOKEN, 1_050e8);
        assertEq(vault.totalAssetsInMarket(MARKET_ID), 1_050e6, "g (pre-settle): market == S (self-move, unchanged)");
        _setDexEquity(XYZ_DEX, int64(uint64(uint256(0))));
        core.setSpotBalance(address(vault), HyperCoreLib.USDC_TOKEN, HyperCoreMockState.SpotBalance({total: 1_050e8, hold: 0, entryNtl: 0}));
        _settleAndRefresh();
        assertEq(vault.totalAssetsInMarket(MARKET_ID), 1_050e6, "g: NAV unchanged after moving equity back to spot");
        assertEq(vault.totalAssets(), 1_050e6, "g: totalAssets unchanged");

        // h. send fuse Core -> EVM bridge: spot -> spot to the token's system address. Before this
        // action: live Core value S = $1050, out-transit amount A = $1050 (the full spot balance).
        // HyperCoreSendFuse._cachedValueWad caches S - A = 0 for this route, so totalAssets() is
        // temporarily $1050 lower (the EVM credit has not landed yet) until it is mocked below.
        uint256 evmBalanceBefore = usdc.balanceOf(address(vault));
        _executeSpotSend(usdcSystemAddress, HyperCoreLib.USDC_TOKEN, 1_050e8);
        assertEq(
            coreWriter.lastAction(),
            HyperCoreLib.encodeSpotSend(usdcSystemAddress, HyperCoreLib.USDC_TOKEN, uint64(1_050e8)),
            "h: spot-send payload"
        );
        assertEq(vault.totalAssetsInMarket(MARKET_ID), 0, "h (pre-settle): market == S - A == 0");
        assertEq(vault.totalAssets(), 0, "h (pre-settle): totalAssets temporarily 0 (EVM credit not yet mocked)");

        core.setSpotBalance(address(vault), HyperCoreLib.USDC_TOKEN, HyperCoreMockState.SpotBalance({total: 0, hold: 0, entryNtl: 0}));
        usdc.mint(address(vault), 1_050e6); // simulate the bridged EVM credit
        _settleAndRefresh();

        assertEq(usdc.balanceOf(address(vault)) - evmBalanceBefore, 1_050e6, "h: EVM balance credited $1050");
        assertEq(vault.totalAssetsInMarket(MARKET_ID), 0, "h: market emptied");
        assertEq(vault.totalAssets(), 1_050e6, "h: final NAV == initial deposit + $50");
    }

    // ---------------------------------------------------------------------
    // 2. Rejected order leaves NAV unchanged.
    // ---------------------------------------------------------------------

    function testRejectedOrderLeavesNavUnchanged() public {
        _activateWithBaseline(500e6);

        _executeOrder(XYZ_ASSET, true, 100e8, 1e8, false, HyperCoreLib.TIF_IOC, 1);
        // Core rejects: mock state is left untouched.
        _settleAndRefresh();

        assertEq(vault.totalAssetsInMarket(MARKET_ID), 500e6, "NAV equals the value before the rejected order");
    }

    // ---------------------------------------------------------------------
    // 3. Rejected own-dex transfer leaves NAV unchanged.
    // ---------------------------------------------------------------------

    function testRejectedTransferLeavesNavUnchanged() public {
        _activate();
        core.setSpotBalance(address(vault), HyperCoreLib.USDC_TOKEN, HyperCoreMockState.SpotBalance({total: 500e8, hold: 0, entryNtl: 0}));
        _refresh();
        assertEq(vault.totalAssetsInMarket(MARKET_ID), 500e6, "baseline");

        _executeSendAsset(address(vault), HyperCoreLib.SPOT_DEX, XYZ_DEX, HyperCoreLib.USDC_TOKEN, 100e8);
        // Core does not apply the send: mock state is left untouched.
        _settleAndRefresh();

        assertEq(vault.totalAssetsInMarket(MARKET_ID), 500e6, "NAV equals the value before the rejected send");
    }

    // ---------------------------------------------------------------------
    // 7. Late GTC fill appears at the next priced operation.
    // ---------------------------------------------------------------------

    function testLateGtcFillPricesNextDeposit() public {
        _activate();
        // Starting mock state: the vault already holds $1,000 collateral on xyz, refreshed into
        // market 55 before the order.
        _setDexEquity(XYZ_DEX, int64(uint64(uint256(BASE_COLLATERAL_USD6))));
        _refresh();
        assertEq(vault.totalAssetsInMarket(MARKET_ID), BASE_COLLATERAL_USD6, "baseline S == $1000 collateral");

        vm.prank(TestAddresses.USER);
        vault.deposit(1_000e6, TestAddresses.USER);
        assertEq(vault.totalAssets(), 2_000e6, "EVM $1000 + market S $1000");

        _executeOrder(XYZ_ASSET, true, 100e8, 1e8, false, HyperCoreLib.TIF_GTC, 1);
        // Order does not fill: settles by timing with NAV unchanged at S == $1000.
        _settleAndRefresh();
        assertEq(vault.totalAssetsInMarket(MARKET_ID), BASE_COLLATERAL_USD6, "GTC order left unfilled: NAV unchanged");

        // Later, the mock fills it -- no `execute` call accompanies this: live equity = collateral
        // ($1000) + PnL ($50) = $1050.
        core.setPosition(
            address(vault), XYZ_READ_INDEX,
            HyperCoreMockState.Position({szi: XYZ_POSITION_SZI, entryNtl: XYZ_POSITION_ENTRY_NTL, isolatedRawUsd: 0, leverage: 20, isIsolated: false})
        );
        uint256 liveEquity = BASE_COLLATERAL_USD6 + FILL_PNL_USD6; // $1050
        _setDexEquity(XYZ_DEX, int64(uint64(uint256(liveEquity))));

        // On the still-stale cache (market == S == $1000), a deposit would price at this many shares.
        uint256 staleShares = vault.previewDeposit(500e6);

        // Compute what the refreshed NAV would price the same deposit at, then roll back to the
        // stale-cache state so the real deposit below is the one that must trigger the pre-hook
        // refresh.
        uint256 snapshot = vm.snapshot();
        vm.prank(TestAddresses.ATOMIST);
        vault.updateMarketsBalances(_marketArray());
        uint256 expectedShares = vault.previewDeposit(500e6);
        vm.revertTo(snapshot);

        assertEq(vault.totalAssetsInMarket(MARKET_ID), BASE_COLLATERAL_USD6, "cache is still stale before the deposit");
        vm.prank(TestAddresses.USER);
        uint256 minted = vault.deposit(500e6, TestAddresses.USER);

        assertEq(minted, expectedShares, "deposit prices shares against the refreshed NAV, not the stale one");
        assertLt(minted, staleShares, "NAV went up, so the deposit mints fewer shares than on the stale cache");
        assertEq(vault.totalAssetsInMarket(MARKET_ID), liveEquity, "capital-flow pre-hook refreshed market 55 to $1050");
        assertEq(vault.totalAssets(), 2_550e6, "totalAssets == $2050 refreshed total + $500 deposit == $2550");
    }

    // ---------------------------------------------------------------------
    // 8. Cancel on the HIP-3 market.
    // ---------------------------------------------------------------------

    function testCancelOnHip3Market() public {
        _activateWithBaseline(0);

        _executeCancelByCloid(XYZ_ASSET, 555);
        assertEq(
            coreWriter.lastAction(), HyperCoreLib.encodeCancelByCloid(XYZ_ASSET, 555), "cancel payload"
        );
        _settleAndRefresh();
        assertEq(vault.totalAssetsInMarket(MARKET_ID), 0, "NAV unchanged by a cancel");
    }

    // ---------------------------------------------------------------------
    // 9. Second market is not tradable.
    // ---------------------------------------------------------------------

    function testSecondMarketIsNotTradable() public {
        _activate();

        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreOrderFuse.HyperCoreOrderFuseMarketNotGranted.selector, uint32(0))
        );
        _executeOrder(0, true, 100e8, 1e8, false, HyperCoreLib.TIF_IOC, 1);

        _grantSubstrates(XYZ_DEX_BITMAP, true, true);

        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreOrderFuse.HyperCoreOrderFuseSingleMarketRequired.selector, uint256(2))
        );
        _executeOrder(0, true, 100e8, 1e8, false, HyperCoreLib.TIF_IOC, 2);

        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreOrderFuse.HyperCoreOrderFuseSingleMarketRequired.selector, uint256(2))
        );
        _executeOrder(XYZ_ASSET, true, 100e8, 1e8, false, HyperCoreLib.TIF_IOC, 3);
    }

    // ---------------------------------------------------------------------
    // 10. Unconfigured dex cannot be funded or traded.
    // ---------------------------------------------------------------------

    function testUnconfiguredDexCannotBeFundedOrTraded() public {
        _grantSubstrates(0, false, false);
        _activate();

        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreSendFuse.HyperCoreSendFuseUnsupportedDex.selector, XYZ_DEX)
        );
        _executeSendAsset(address(vault), HyperCoreLib.SPOT_DEX, XYZ_DEX, HyperCoreLib.USDC_TOKEN, 1e8);
        assertEq(coreWriter.lastAction(), bytes(""), "no CoreWriter action recorded");

        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreOrderFuse.HyperCoreOrderFusePerpDexNotConfigured.selector, XYZ_DEX)
        );
        _executeOrder(XYZ_ASSET, true, 100e8, 1e8, false, HyperCoreLib.TIF_IOC, 1);
        assertEq(coreWriter.lastAction(), bytes(""), "no CoreWriter action recorded");

        // With the dex configured but under-equipped, a xyz -> spot send exceeding equity reverts.
        _grantSubstrates(XYZ_DEX_BITMAP, true, false);
        _setDexEquity(XYZ_DEX, int64(uint64(uint256(100e6))));
        vm.expectRevert(
            abi.encodeWithSelector(
                HyperCoreSendFuse.HyperCoreSendFuseInsufficientDexEquity.selector, XYZ_DEX, uint256(100e6), uint256(101e6)
            )
        );
        _executeSendAsset(address(vault), XYZ_DEX, HyperCoreLib.SPOT_DEX, HyperCoreLib.USDC_TOKEN, 101e8);
    }

    // ---------------------------------------------------------------------
    // Shared setup / mock helpers
    // ---------------------------------------------------------------------

    function _installHooks() private {
        address pendingHook = address(new HyperCorePendingActionPreHook());
        address capitalFlowHook = address(new HyperCoreCapitalFlowPreHook());

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = PlasmaVault.execute.selector;
        selectors[1] = PlasmaVault.updateMarketsBalances.selector;
        selectors[2] = PlasmaVault.deposit.selector;
        selectors[3] = PlasmaVault.depositWithPermit.selector;
        selectors[4] = PlasmaVault.mint.selector;
        selectors[5] = PlasmaVault.withdraw.selector;
        selectors[6] = PlasmaVault.redeem.selector;
        selectors[7] = PlasmaVault.redeemFromRequest.selector;

        address[] memory implementations = new address[](8);
        implementations[0] = pendingHook;
        implementations[1] = pendingHook;
        for (uint256 i = 2; i < 8; ++i) {
            implementations[i] = capitalFlowHook;
        }

        bytes32[][] memory substrates = new bytes32[][](8);
        for (uint256 i; i < 8; ++i) {
            substrates[i] = new bytes32[](0);
        }

        vm.prank(TestAddresses.ATOMIST);
        PlasmaVaultGovernance(address(vault)).setPreHookImplementations(selectors, implementations, substrates);
    }

    /// @dev Full substrate list for market 55 (grantMarketSubstrates replaces the whole array).
    function _grantSubstrates(
        uint240 dexBitmap_,
        bool includeDexConfig_,
        bool grantNativeMarket_
    ) private {
        uint256 n = 6;
        if (includeDexConfig_) n += 1;
        if (grantNativeMarket_) n += 1;

        bytes32[] memory subs = new bytes32[](n);
        uint256 i;
        subs[i++] = HyperCoreSubstrateLib.encodeSpotToken(HyperCoreLib.USDC_TOKEN, address(usdc));
        subs[i++] = HyperCoreSubstrateLib.encodeSendCap(HyperCoreLib.USDC_TOKEN, type(uint128).max);
        subs[i++] = HyperCoreSubstrateLib.encodeDestination(usdcSystemAddress);
        subs[i++] = HyperCoreSubstrateLib.encodeDestination(address(vault));
        subs[i++] = HyperCoreSubstrateLib.encodePerpMarket(XYZ_ASSET, 1_000_000e6, false);
        if (grantNativeMarket_) {
            subs[i++] = HyperCoreSubstrateLib.encodePerpMarket(0, 1_000_000e6, false);
        }
        if (includeDexConfig_) {
            subs[i++] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.PerpDexIds, dexBitmap_);
        }
        subs[i++] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.SpotSendBridgeEnabled, 1);

        vm.prank(TestAddresses.FUSE_MANAGER);
        PlasmaVaultHelper.addSubstratesToMarket(vault, MARKET_ID, subs);
    }

    /// @dev Registers read index 10002 (xyz:NVDA) with the real mainnet `perpAssetInfo` metadata and
    ///      mark/oracle prices, decoded from `HyperCoreHip3RawFixtures` rather than hand-picked values.
    function _registerXyzNvdaFromFixture() private {
        HyperCoreLib.PerpAssetInfo memory info =
            abi.decode(HyperCoreHip3RawFixtures.perpAssetInfoXyzNvda(), (HyperCoreLib.PerpAssetInfo));
        core.setPerpAssetInfo(
            XYZ_READ_INDEX,
            HyperCoreMockState.PerpAssetInfo({
                coin: info.coin,
                marginTableId: info.marginTableId,
                szDecimals: info.szDecimals,
                maxLeverage: info.maxLeverage,
                onlyIsolated: info.onlyIsolated
            })
        );
        core.setMarkPx(XYZ_READ_INDEX, HyperCoreHip3RawFixtures.nvdaMarkPx());
        core.setOraclePx(XYZ_READ_INDEX, HyperCoreHip3RawFixtures.nvdaOraclePx());
    }

    function _activate() private {
        core.setCoreUserExists(address(vault), true);
    }

    function _activateWithBaseline(uint256 dexEquityUsd6_) private {
        _activate();
        _setDexEquity(XYZ_DEX, int64(uint64(dexEquityUsd6_)));
        _refresh();
    }

    function _setDexEquity(uint32 dex_, int64 equityUsd6_) private {
        core.setAccountMarginSummary(
            dex_, address(vault),
            HyperCoreMockState.AccountMarginSummary({accountValue: equityUsd6_, marginUsed: 0, ntlPos: 0, rawUsd: equityUsd6_})
        );
    }

    function _marketArray() private pure returns (uint256[] memory markets) {
        markets = new uint256[](1);
        markets[0] = MARKET_ID;
    }

    function _refresh() private {
        vm.prank(TestAddresses.ATOMIST);
        vault.updateMarketsBalances(_marketArray());
    }

    function _settleAndRefresh() private {
        vm.warp(block.timestamp + 61);
        core.setL1BlockNumber(core.getL1BlockNumber() + 1);
        _refresh();
    }

    function _isPending() private view returns (bool) {
        return uint64(uint256(vm.load(address(vault), PENDING_SLOT))) != 0;
    }

    function _pendingActionNonce() private view returns (uint256) {
        return uint256(vm.load(address(vault), bytes32(uint256(PENDING_SLOT) + 5)));
    }

    /// @dev `vm.expectRevert` requires the exact revert data here, not just the selector, so this
    ///      reads the live `pendingUntil` value the error is reverted with.
    function _pendingRevertData() private view returns (bytes memory) {
        uint64 pendingUntil = uint64(uint256(vm.load(address(vault), PENDING_SLOT)));
        return abi.encodeWithSelector(HyperCorePendingLib.HyperCoreActionPending.selector, pendingUntil);
    }

    function _decodeOrderPayload(
        bytes memory data_
    ) private view returns (uint32 asset, bool isBuy, uint64 limitPx, uint64 sz, bool reduceOnly, uint8 tif, uint128 cloid) {
        (, , bytes memory payload) = coreWriter.decodeHeader(data_);
        (asset, isBuy, limitPx, sz, reduceOnly, tif, cloid) =
            abi.decode(payload, (uint32, bool, uint64, uint64, bool, uint8, uint128));
    }

    // ---------------------------------------------------------------------
    // Fuse execution helpers
    // ---------------------------------------------------------------------

    function _executeDeposit(uint256 amount_) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(depositFuse),
            data: abi.encodeCall(
                HyperCoreDepositFuse.enter,
                (HyperCoreDepositFuseEnterData({tokenIndex: HyperCoreLib.USDC_TOKEN, amount: amount_}))
            )
        });
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);
    }

    function _executeSendAsset(
        address destination_, uint32 sourceDex_, uint32 destinationDex_, uint64 tokenIndex_, uint64 amountWei_
    ) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(sendFuse),
            data: abi.encodeCall(
                HyperCoreSendFuse.enterSendAsset,
                (
                    HyperCoreSendFuseSendAssetData({
                        destination: destination_, sourceDex: sourceDex_, destinationDex: destinationDex_,
                        tokenIndex: tokenIndex_, amountWei: amountWei_
                    })
                )
            )
        });
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);
    }

    function _executeSpotSend(address destination_, uint64 tokenIndex_, uint64 amountWei_) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(sendFuse),
            data: abi.encodeCall(
                HyperCoreSendFuse.enterSpotSend,
                (HyperCoreSendFuseSpotSendData({destination: destination_, tokenIndex: tokenIndex_, amountWei: amountWei_}))
            )
        });
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);
    }

    function _executeOrder(
        uint32 asset_, bool isBuy_, uint64 limitPx_, uint64 sz_, bool reduceOnly_, uint8 tif_, uint128 cloid_
    ) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(orderFuse),
            data: abi.encodeCall(
                HyperCoreOrderFuse.enter,
                (
                    HyperCoreOrderFuseEnterData({
                        asset: asset_, isBuy: isBuy_, limitPx: limitPx_, sz: sz_, reduceOnly: reduceOnly_, tif: tif_, cloid: cloid_
                    })
                )
            )
        });
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);
    }

    function _executeCancelByCloid(uint32 asset_, uint128 cloid_) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction({
            fuse: address(cancelFuse),
            data: abi.encodeCall(
                HyperCoreCancelFuse.enterCancelByCloid, (HyperCoreCancelFuseCancelByCloidData({asset: asset_, cloid: cloid_}))
            )
        });
        vm.prank(TestAddresses.ALPHA);
        vault.execute(actions);
    }
}

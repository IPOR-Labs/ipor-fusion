// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {RewardsClaimManager} from "../../../contracts/managers/rewards/RewardsClaimManager.sol";

import {PlasmaVaultHelper} from "../../test_helpers/PlasmaVaultHelper.sol";
import {IporFusionAccessManagerHelper} from "../../test_helpers/IporFusionAccessManagerHelper.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";

import {HyperCoreTestHelper, HyperCoreMockUsdc} from "./HyperCoreTestHelper.sol";

import {HyperCoreBalanceFuse} from "../../../contracts/fuses/hypercore/HyperCoreBalanceFuse.sol";
import {HyperCoreDepositFuse, HyperCoreDepositFuseEnterData} from "../../../contracts/fuses/hypercore/HyperCoreDepositFuse.sol";
import {HyperCoreMarginFuse, HyperCoreMarginFuseEnterData} from "../../../contracts/fuses/hypercore/HyperCoreMarginFuse.sol";
import {HyperCoreOrderFuse, HyperCoreOrderFuseEnterData} from "../../../contracts/fuses/hypercore/HyperCoreOrderFuse.sol";
import {
    HyperCoreCancelFuse,
    HyperCoreCancelFuseCancelByOidData
} from "../../../contracts/fuses/hypercore/HyperCoreCancelFuse.sol";
import {
    HyperCoreSendFuse,
    HyperCoreSendFuseSendAssetData
} from "../../../contracts/fuses/hypercore/HyperCoreSendFuse.sol";
import {HyperCoreBuilderFeeFuse} from "../../../contracts/fuses/hypercore/HyperCoreBuilderFeeFuse.sol";
import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {HyperCorePendingLib} from "../../../contracts/fuses/hypercore/lib/HyperCorePendingLib.sol";

import {CoreSimulatorLib} from "./simulation/CoreSimulatorLib.sol";
import {HyperCore} from "./simulation/HyperCore.sol";
import {PrecompileLib} from "./simulation/src/PrecompileLib.sol";
import {SimCoreDepositWallet} from "./simulation/SimCoreDepositWallet.sol";

/// @title HyperCoreFlowSimulationTest
/// @notice Offline, no-RPC end-to-end walk of the HyperCore fuses (IL-8416 M3) against the vendored
///         `hyper-evm-lib` simulator (see `test/fuses/hypercore/simulation/VENDORED.md`), following the
///         flow described in `chat/PLAN.md` section 8.3: deposit USDC EVM->Core, move it to perp margin,
///         open a short with an IOC order, read the position back through the 0x800 precompile, place and
///         cancel a resting GTC order, close the short with a reduce-only IOC, move USDC back to spot and
///         send it back to the vault's EVM balance.
/// @dev Adaptations to the simulator, documented per the task brief:
///      - Perp orders in this simulator snapshot (commit 4eb7ab04) never rest: `executePerpLimitOrder`
///        (test/fuses/hypercore/simulation/hyper-core/CoreExecution.sol:70-102) ignores TIF entirely and
///        either fills immediately (limit price crosses `markPx`) or is silently dropped -- there is no
///        perp order book/oid tracking (`_pendingOrders` is only used for spot). So the GTC+cancel step
///        places a GTC order with a limit price that intentionally does NOT cross the mark price (so it
///        is dropped, not filled) and then cancels a synthetic oid; `HyperCoreCancelFuse` still exercises
///        its full validate/enqueue/settle path even though the simulator's `executeRawAction` has no
///        handler for CANCEL_BY_OID (actions 10/11) or APPROVE_BUILDER_FEE (12) and treats them as no-ops.
///      - `CoreSimulatorLib.init()` seeds USDC (token 0) with `evmContract == address(0)` in offline mode
///        (no linked EVM ERC20). This test re-registers token 0 via `HyperCore.registerTokenInfo` right
///        after `init()`, pointing `evmContract` at a local `SimCoreDepositWallet` shim (see
///        `simulation/SimCoreDepositWallet.sol`) wrapping the vault's own mock USDC, matching
///        `HyperCoreDepositFuse`'s CoreDepositWallet routing for token 0: the fuse now calls
///        `depositFor` on `tokenInfo(0).evmContract` rather than transferring USDC to the token's
///        system address, so the shim pulls the USDC via `transferFrom` and credits Core spot directly
///        through `HyperCore.executeTokenTransfer`. `evmExtraWeiDecimals: -2` converts the mock's 6 EVM
///        decimals to HyperCore's 8-decimal spot wei (mirroring the upstream USDT0 seed).
contract HyperCoreFlowSimulationTest is Test {
    using IporFusionAccessManagerHelper for IporFusionAccessManager;

    uint256 private constant MARKET_ID = IporFusionMarkets.HYPERCORE;
    uint64 private constant USDC_TOKEN = 0;
    uint32 private constant HYPE_PERP = 150;
    uint128 private constant CLOID_1 = 1;
    uint128 private constant CLOID_2 = 2;
    uint128 private constant CLOID_3 = 3;

    PlasmaVault private _vault;
    address private _withdrawManager;
    HyperCoreMockUsdc private _usdc;
    PriceOracleMiddleware private _oracle;
    IporFusionAccessManager private _accessManager;
    HyperCore private _hyperCore;
    SimCoreDepositWallet private _depositWallet;

    HyperCoreBalanceFuse private _balanceFuse;
    HyperCoreDepositFuse private _depositFuse;
    HyperCoreMarginFuse private _marginFuse;
    HyperCoreOrderFuse private _orderFuse;
    HyperCoreCancelFuse private _cancelFuse;
    HyperCoreSendFuse private _sendFuse;
    HyperCoreBuilderFeeFuse private _builderFeeFuse;

    address private _user = makeAddr("user");
    address private _builder = makeAddr("builder");

    function setUp() public {
        // --- vendored offline HyperCore simulator ---
        _hyperCore = CoreSimulatorLib.init();
        CoreSimulatorLib.setOfflineMode(true);
        // Surface any dropped/reverted queued CoreWriter action as a loud test failure instead of a
        // silent no-op, so a broken step (e.g. an order that fails to fill) cannot masquerade as success.
        CoreSimulatorLib.setRevertOnFailure(true);

        // --- minimal PlasmaVault with a HyperCore market wired ---
        vm.startPrank(TestAddresses.ATOMIST);
        (_vault, _withdrawManager, _usdc, _oracle) = HyperCoreTestHelper.deployVaultWithHyperCoreMarket(
            TestAddresses.ATOMIST
        );
        _accessManager = IporFusionAccessManager(_vault.authority());
        _accessManager.setupInitRoles(
            _vault,
            _withdrawManager,
            address(new RewardsClaimManager(address(_accessManager), address(_vault)))
        );
        vm.stopPrank();

        // Re-register HyperCore's USDC (token 0) to point at a local SimCoreDepositWallet shim wrapping
        // this vault's own underlying mock USDC, matching HyperCoreDepositFuse's CoreDepositWallet
        // routing for token 0 (`tokenInfo(0).evmContract` is the wallet, not the USDC ERC20 itself). See
        // contract NatSpec and `simulation/SimCoreDepositWallet.sol` for why this is needed offline.
        _depositWallet = new SimCoreDepositWallet(address(_usdc), USDC_TOKEN);
        PrecompileLib.TokenInfo memory usdcInfo = PrecompileLib.TokenInfo({
            name: "USDC",
            spots: new uint64[](0),
            deployerTradingFeeShare: 0,
            deployer: address(0),
            evmContract: address(_depositWallet),
            szDecimals: 8,
            weiDecimals: 8,
            evmExtraWeiDecimals: -2
        });
        _hyperCore.registerTokenInfo(USDC_TOKEN, usdcInfo);

        // --- price oracle: $1.00 for the mock USDC underlying ---
        MockChainlinkFeed usdcFeed = new MockChainlinkFeed(1e8, 8);
        address[] memory assets = new address[](1);
        assets[0] = address(_usdc);
        address[] memory sources = new address[](1);
        sources[0] = address(usdcFeed);
        vm.startPrank(TestAddresses.ATOMIST);
        _oracle.setAssetsPricesSources(assets, sources);
        vm.stopPrank();

        // --- fuses ---
        _balanceFuse = new HyperCoreBalanceFuse(MARKET_ID);
        _depositFuse = new HyperCoreDepositFuse(MARKET_ID);
        _marginFuse = new HyperCoreMarginFuse(MARKET_ID);
        _orderFuse = new HyperCoreOrderFuse(MARKET_ID);
        _cancelFuse = new HyperCoreCancelFuse(MARKET_ID);
        _sendFuse = new HyperCoreSendFuse(MARKET_ID);
        _builderFeeFuse = new HyperCoreBuilderFeeFuse(MARKET_ID);

        address[] memory fuses = new address[](6);
        fuses[0] = address(_depositFuse);
        fuses[1] = address(_marginFuse);
        fuses[2] = address(_orderFuse);
        fuses[3] = address(_cancelFuse);
        fuses[4] = address(_sendFuse);
        fuses[5] = address(_builderFeeFuse);

        vm.startPrank(TestAddresses.FUSE_MANAGER);
        PlasmaVaultHelper.addFusesToVault(_vault, fuses);
        PlasmaVaultHelper.addBalanceFusesToVault(_vault, MARKET_ID, address(_balanceFuse));

        // NOTE: PlasmaVaultConfigLib.grantMarketSubstrates() REPLACES the whole substrate list for the
        // market on every call, so every grant must go through in a single call.
        bytes32[] memory substrates = new bytes32[](8);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(USDC_TOKEN, address(_usdc));
        substrates[1] = HyperCoreSubstrateLib.encodePerpMarket(HYPE_PERP, 1_000_000e6, false);
        substrates[2] = HyperCoreSubstrateLib.encodeDestination(HyperCoreLib.systemAddress(USDC_TOKEN));
        substrates[3] = HyperCoreSubstrateLib.encodeDestination(address(_vault));
        substrates[4] = HyperCoreSubstrateLib.encodeBuilder(_builder, 100);
        substrates[5] = HyperCoreSubstrateLib.encodeSendCap(USDC_TOKEN, type(uint128).max);
        substrates[6] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.WindowTransferSeconds, 2);
        substrates[7] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.MaxUsdClassTransferUsd6, 1_000_000e6);
        PlasmaVaultHelper.addSubstratesToMarket(_vault, MARKET_ID, substrates);
        vm.stopPrank();

        // --- fund the vault via a real deposit ---
        _usdc.mint(_user, 1_000_000e6);
        vm.startPrank(_user);
        _usdc.approve(address(_vault), 1_000_000e6);
        _vault.deposit(1_000_000e6, _user);
        vm.stopPrank();
    }

    /// @dev Advances the HyperCore simulator far enough (timestamp + block number) to both let
    ///      `CoreSimulatorLib.nextBlock()` process the queued CoreWriter action and satisfy
    ///      `HyperCorePendingLib`'s TIMING settlement gate (`block.timestamp >= pendingUntil` and a later
    ///      `HyperCoreLib.l1BlockNumber()`, which this vendoring backs with `block.number`; see
    ///      simulation/PrecompileSim.sol).
    function _settle(uint64 windowSeconds_) private {
        vm.warp(block.timestamp + uint256(windowSeconds_) + 1);
        CoreSimulatorLib.nextBlock();
    }

    function _refreshAndTotalAssets() private returns (uint256) {
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = MARKET_ID;
        vm.prank(TestAddresses.ATOMIST);
        _vault.updateMarketsBalances(marketIds);
        return _vault.totalAssets();
    }

    // Shared across the phase helpers below to keep each function's local-variable count small enough
    // to avoid "stack too deep" (no via-ir; see project CLAUDE.md).
    uint256 private _totalAssetsBefore;
    uint256 private _totalAssetsAfterDeposit;
    uint256 private _totalAssetsAfterMargin;
    int64 private _expectedSzi;

    function testHyperCoreFlow() public {
        _totalAssetsBefore = _vault.totalAssets();
        assertEq(_totalAssetsBefore, 1_000_000e6, "vault should hold the deposited USDC on the EVM side");

        _phaseDeposit();
        _phaseMarginToPerp();
        _phaseOpenShort();
        _phaseGtcAndCancel();
        _phaseCloseShort();
        _phaseMarginToSpotAndSendBack();
    }

    // 1) EVM -> Core deposit of 100,000 USDC.
    function _phaseDeposit() private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_depositFuse),
            abi.encodeWithSelector(
                HyperCoreDepositFuse.enter.selector, HyperCoreDepositFuseEnterData({tokenIndex: USDC_TOKEN, amount: 100_000e6})
            )
        );
        vm.prank(TestAddresses.ALPHA);
        _vault.execute(actions);
        _settle(2);

        // The USDC (token 0) leg must go through the CoreDepositWallet's `depositFor`, not a plain
        // ERC20 transfer to the token's system address (see HyperCoreDepositFuse._transferToCore).
        assertEq(_depositWallet.depositForCallCount(), 1, "USDC deposit should route through the CoreDepositWallet");
        assertEq(_depositWallet.lastRecipient(), address(_vault), "wallet should credit the vault's HyperCore account");
        assertEq(_depositWallet.lastAmount(), 100_000e6, "wallet should pull the full rounded EVM amount");
        assertEq(_depositWallet.lastDestinationDex(), HyperCoreLib.SPOT_DEX, "wallet deposit should target the spot dex");
        assertEq(
            IERC20(address(_usdc)).allowance(address(_vault), address(_depositWallet)),
            0,
            "fuse should reset the wallet's USDC allowance after depositFor"
        );

        assertTrue(HyperCoreLib.coreUserExists(address(_vault)), "vault HyperCore account should now be activated");
        _totalAssetsAfterDeposit = _refreshAndTotalAssets();
        assertApproxEqAbs(
            _totalAssetsAfterDeposit, _totalAssetsBefore, 2e6, "NAV should be ~flat across an EVM<->Core deposit"
        );
    }

    // 2) usdClassTransfer: move 50,000 USDC of spot balance into native perp margin.
    function _phaseMarginToPerp() private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_marginFuse),
            abi.encodeWithSelector(
                HyperCoreMarginFuse.enter.selector, HyperCoreMarginFuseEnterData({usd6: 50_000e6, toPerp: true})
            )
        );
        vm.prank(TestAddresses.ALPHA);
        _vault.execute(actions);
        _settle(2);

        _totalAssetsAfterMargin = _refreshAndTotalAssets();
        assertApproxEqAbs(
            _totalAssetsAfterMargin, _totalAssetsAfterDeposit, 1e6, "spot->perp margin move should be NAV neutral"
        );
    }

    // 3) IOC short on the HYPE perp; mark price set so the order crosses and fills immediately.
    function _phaseOpenShort() private {
        CoreSimulatorLib.forcePerpLeverage(address(_vault), HYPE_PERP, 10);
        CoreSimulatorLib.setMarkPx(HYPE_PERP, 400_000); // -> $40.00 in the 8-decimal comparison scale

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_orderFuse),
            abi.encodeWithSelector(
                HyperCoreOrderFuse.enter.selector,
                HyperCoreOrderFuseEnterData({
                    asset: HYPE_PERP,
                    isBuy: false,
                    limitPx: 35e8, // sell fills when markPx (40) >= limitPx (35)
                    sz: 1e8, // 1.00 HYPE, a multiple of the 1e6 lot size for szDecimals=2
                    reduceOnly: false,
                    tif: HyperCoreLib.TIF_IOC,
                    cloid: CLOID_1
                })
            )
        );
        vm.prank(TestAddresses.ALPHA);
        _vault.execute(actions);
        _settle(10);

        // NOTE: the position precompile reports `szi` in the asset's native szDecimals units
        // (size * 10^szDecimals), not in the CoreWriter order's 1e8-fixed-point `sz` units. For HYPE
        // (szDecimals = 2), an order of sz = 1e8 (1.00 HYPE) settles as szi = -100, not -1e8.
        _expectedSzi = -int64(uint64(1 * 10 ** HyperCoreLib.perpAssetInfo(HYPE_PERP).szDecimals));
        HyperCoreLib.Position memory position = HyperCoreLib.position(address(_vault), HYPE_PERP);
        assertEq(position.szi, _expectedSzi, "short IOC should have filled for 1.00 HYPE");

        uint256 totalAssetsAfterShort = _refreshAndTotalAssets();
        assertApproxEqAbs(
            totalAssetsAfterShort,
            _totalAssetsAfterMargin,
            1e6,
            "opening the short at mark should be ~NAV neutral before funding/fees"
        );
    }

    // 5) GTC order placed away from the market (does not cross) then cancelled by oid.
    //    See contract NatSpec: this simulator snapshot never rests perp orders, so the GTC leg
    //    exercises the fuse's validate/enqueue path rather than a real resting-order fill/cancel.
    function _phaseGtcAndCancel() private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_orderFuse),
            abi.encodeWithSelector(
                HyperCoreOrderFuse.enter.selector,
                HyperCoreOrderFuseEnterData({
                    asset: HYPE_PERP,
                    isBuy: false,
                    limitPx: 45e8, // above mark (40): a sell does NOT cross, order is dropped, not filled
                    sz: 1e8,
                    reduceOnly: false,
                    tif: HyperCoreLib.TIF_GTC,
                    cloid: CLOID_2
                })
            )
        );
        vm.prank(TestAddresses.ALPHA);
        _vault.execute(actions);
        _settle(10);

        HyperCoreLib.Position memory positionAfterGtc = HyperCoreLib.position(address(_vault), HYPE_PERP);
        assertEq(positionAfterGtc.szi, _expectedSzi, "non-crossing GTC order must not change the position");

        actions[0] = FuseAction(
            address(_cancelFuse),
            abi.encodeWithSelector(
                HyperCoreCancelFuse.enterCancelByOid.selector, HyperCoreCancelFuseCancelByOidData({asset: HYPE_PERP, oid: 1})
            )
        );
        vm.prank(TestAddresses.ALPHA);
        _vault.execute(actions);
        _settle(10);
    }

    // 6) Reduce-only IOC buy closes the short (mark still $40, limit $45 crosses on a buy).
    function _phaseCloseShort() private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_orderFuse),
            abi.encodeWithSelector(
                HyperCoreOrderFuse.enter.selector,
                HyperCoreOrderFuseEnterData({
                    asset: HYPE_PERP,
                    isBuy: true,
                    limitPx: 45e8,
                    sz: 1e8,
                    reduceOnly: true,
                    tif: HyperCoreLib.TIF_IOC,
                    cloid: CLOID_3
                })
            )
        );
        vm.prank(TestAddresses.ALPHA);
        _vault.execute(actions);
        _settle(10);

        HyperCoreLib.Position memory positionAfterClose = HyperCoreLib.position(address(_vault), HYPE_PERP);
        assertEq(positionAfterClose.szi, 0, "reduce-only IOC should have closed the short");
    }

    // 7) usdClassTransfer back to spot, then 8) Core -> EVM sendAsset back to the vault's EVM balance.
    function _phaseMarginToSpotAndSendBack() private {
        uint64 perpBalanceUsd6 = HyperCoreLib.withdrawable(address(_vault));
        assertGt(perpBalanceUsd6, 0, "perp margin should be nonzero after the round trip");

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_marginFuse),
            abi.encodeWithSelector(
                HyperCoreMarginFuse.enter.selector, HyperCoreMarginFuseEnterData({usd6: perpBalanceUsd6, toPerp: false})
            )
        );
        vm.prank(TestAddresses.ALPHA);
        _vault.execute(actions);
        _settle(2);

        HyperCoreLib.SpotBalance memory spotBalance = HyperCoreLib.spotBalance(address(_vault), USDC_TOKEN);
        uint64 sendable = spotBalance.total - spotBalance.hold;
        assertGt(sendable, 0, "vault should hold a spot USDC balance to send back to the EVM side");

        uint256 evmUsdcBefore = _usdc.balanceOf(address(_vault));
        actions[0] = FuseAction(
            address(_sendFuse),
            abi.encodeWithSelector(
                HyperCoreSendFuse.enterSendAsset.selector,
                HyperCoreSendFuseSendAssetData({
                    destination: HyperCoreLib.systemAddress(USDC_TOKEN),
                    sourceDex: HyperCoreLib.SPOT_DEX,
                    destinationDex: HyperCoreLib.SPOT_DEX,
                    tokenIndex: USDC_TOKEN,
                    amountWei: sendable
                })
            )
        );
        vm.prank(TestAddresses.ALPHA);
        _vault.execute(actions);
        _settle(2);

        uint256 evmUsdcAfter = _usdc.balanceOf(address(_vault));
        assertGt(evmUsdcAfter, evmUsdcBefore, "USDC should be back on the vault's EVM balance after sendAsset");

        uint256 totalAssetsAfterRoundTrip = _refreshAndTotalAssets();
        assertApproxEqRel(
            totalAssetsAfterRoundTrip,
            _totalAssetsBefore,
            0.01e18,
            "NAV should be ~flat (within 1%) after the full round trip, minus fees"
        );
    }

    /// @notice An order on a perp asset that was never granted as a PerpMarket substrate must revert
    ///         before any CoreWriter action is sent.
    function testOrderOnUngrantedMarketReverts() public {
        // Activate the vault's HyperCore account first so the revert exercised below is
        // HyperCoreOrderFuseMarketNotGranted, not the earlier HyperCoreOrderFuseAccountNotActivated check.
        FuseAction[] memory depositActions = new FuseAction[](1);
        depositActions[0] = FuseAction(
            address(_depositFuse),
            abi.encodeWithSelector(
                HyperCoreDepositFuse.enter.selector, HyperCoreDepositFuseEnterData({tokenIndex: USDC_TOKEN, amount: 10_000e6})
            )
        );
        vm.prank(TestAddresses.ALPHA);
        _vault.execute(depositActions);
        _settle(2);

        uint32 ungrantedAsset = 999;
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_orderFuse),
            abi.encodeWithSelector(
                HyperCoreOrderFuse.enter.selector,
                HyperCoreOrderFuseEnterData({
                    asset: ungrantedAsset,
                    isBuy: true,
                    limitPx: 1e8,
                    sz: 1e8,
                    reduceOnly: false,
                    tif: HyperCoreLib.TIF_IOC,
                    cloid: CLOID_1
                })
            )
        );

        vm.prank(TestAddresses.ALPHA);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreOrderFuse.HyperCoreOrderFuseMarketNotGranted.selector, ungrantedAsset));
        _vault.execute(actions);
    }

    /// @notice A second HyperCore action before the first one's pending window has elapsed must revert
    ///         with HyperCoreActionPending.
    function testSecondActionWhilePendingReverts() public {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_depositFuse),
            abi.encodeWithSelector(
                HyperCoreDepositFuse.enter.selector, HyperCoreDepositFuseEnterData({tokenIndex: USDC_TOKEN, amount: 10_000e6})
            )
        );
        vm.prank(TestAddresses.ALPHA);
        _vault.execute(actions);

        // No _settle() here: the pending window has not elapsed yet.
        actions[0] = FuseAction(
            address(_depositFuse),
            abi.encodeWithSelector(
                HyperCoreDepositFuse.enter.selector, HyperCoreDepositFuseEnterData({tokenIndex: USDC_TOKEN, amount: 1_000e6})
            )
        );
        vm.prank(TestAddresses.ALPHA);
        vm.expectRevert(abi.encodeWithSelector(HyperCorePendingLib.HyperCoreActionPending.selector, uint64(block.timestamp + 2)));
        _vault.execute(actions);
    }
}

/// @dev Minimal Chainlink-style price feed returning a constant price, matching the pattern used
///      elsewhere in this test suite (e.g. test/vaults/PlasmaVaultErc4626ComplianceTest.t.sol).
contract MockChainlinkFeed {
    int256 private immutable _price;
    uint8 private immutable _decimals;

    constructor(int256 price_, uint8 decimals_) {
        _price = price_;
        _decimals = decimals_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, _price, block.timestamp, block.timestamp, 1);
    }
}

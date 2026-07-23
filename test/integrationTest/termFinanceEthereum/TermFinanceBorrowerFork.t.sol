// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Errors} from "contracts/libraries/errors/Errors.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {IporFusionMarkets} from "contracts/libraries/IporFusionMarkets.sol";
import {TermFinanceBalanceFuse} from "contracts/fuses/term_finance/TermFinanceBalanceFuse.sol";
import {
    TermFinanceCollateralFuse,
    TermFinanceCollateralFuseEnterData,
    TermFinanceCollateralFuseExitData
} from "contracts/fuses/term_finance/TermFinanceCollateralFuse.sol";
import {
    TermFinanceRepurchaseFuse,
    TermFinanceRepurchaseFuseEnterData
} from "contracts/fuses/term_finance/TermFinanceRepurchaseFuse.sol";
import {IExtTermAuctionBidLocker} from "contracts/fuses/term_finance/ext/IExtTermAuctionBidLocker.sol";
import {IExtTermController} from "contracts/fuses/term_finance/ext/IExtTermController.sol";
import {IExtTermDiscountRateAdapter} from "contracts/fuses/term_finance/ext/IExtTermDiscountRateAdapter.sol";
import {IExtTermRepoCollateralManager} from "contracts/fuses/term_finance/ext/IExtTermRepoCollateralManager.sol";
import {IExtTermRepoServicer} from "contracts/fuses/term_finance/ext/IExtTermRepoServicer.sol";
import {IExtTermRepoToken} from "contracts/fuses/term_finance/ext/IExtTermRepoToken.sol";
import {TermFinanceSubstrateLib} from "contracts/fuses/term_finance/lib/TermFinanceSubstrateLib.sol";

import {TermFinanceBalanceFuseHarness} from "../../unitTest/fuses/term_finance/mocks/TermFinanceBalanceFuseHarness.sol";
import {
    TermFinanceCollateralFuseHarness
} from "../../unitTest/fuses/term_finance/mocks/TermFinanceCollateralFuseHarness.sol";
import {
    TermFinanceRepurchaseFuseHarness
} from "../../unitTest/fuses/term_finance/mocks/TermFinanceRepurchaseFuseHarness.sol";

/// @title TermFinanceBorrowerFork
/// @notice Fork integration tests for the borrower-side Term Finance fuses on live Ethereum
///         mainnet contracts (block 25097999, pinned to match `TermFinanceLiveBalanceFork`).
/// @dev Coverage matrix:
///      - `testForkCollateralFuseTopsUpAndDrawsDownOnLiveCollateralManager` — full lock + unlock
///        cycle via the live `TermRepoCollateralManager` proxy.
///      - `testForkRepurchaseFuseSettlesDebtOnLiveServicer` — vault repays a partial debt
///        through the live `submitRepurchasePayment` pathway (approval routing through
///        `TermRepoLocker`, balance delta accounting, event emission).
///      - `testForkBalanceFuseAggregatesAllLegsCorrectly` — vault holds locked collateral
///        AND has an active borrower obligation; balanceOf aggregates all live legs.
///      - `testForkBalanceFuseDebtReadGatedByTrackedExposure` — vault has tracked
///        exposure but the debt-read mocks a revert; gated-revert semantics fire.
///      - `testForkBalanceFuseStaticcallSafe` — `balanceOf()` is callable via `staticcall`
///        on a position with mixed live legs.
///      - `testForkBalanceFuseHandlesOracleMissingOnCollateral` — collateral oracle returns
///        zero on a TRACKED live borrower; the fuse re-raises
///        `TermFinanceBalanceFusePurchaseTokenPriceZeroForTracked`.
///      - `testForkBalanceFuseFullLifecycleHappyPath` — happy-path E2E: top up collateral,
///        partial repurchase, draw down, NAV evolution.
///
///      NOTE — borrower context via `vm.etch`. Term Finance's
///      `externalLockCollateral` reverts with `ZeroBorrowerRepurchaseObligation()` unless
///      `getBorrowerRepurchaseObligation(msg.sender) != 0`. Establishing a fresh borrower
///      position on a frozen fork requires winning an auction — impossible without an
///      auctioneer signature. We instead **etch the fuse bytecode at the live borrower's
///      address** (`LIVE_BORROWER` = 0x3976747B...e7f3, a borrower with a real ~1.01M USDC
///      obligation at the pinned block), preserving the live `getBorrowerRepurchaseObligation
///      / getCollateralBalance` state while inheriting the fuse logic. The fuse delegatecall
///      context in production is `address(this) == PlasmaVault`, so this etch faithfully
///      mirrors a vault that already holds a Term Finance borrower position.
///
///      INTENTIONALLY SKIPPED (with documented reason — see body comments):
///      - Pre-clearing Bid + BidReveal lifecycle. At the pinned block 25097999 the only
///        BidLocker (`0x4d28...8673`) has already passed `revealTime`; replaying the live
///        submission flow would require either (a) pinning to a different block (would
///        break the lender-side `TermFinanceLiveBalanceFork` invariants verified against
///        this block), or (b) `vm.mockCall`-ing `revealTime` AND `lockBids` to bypass real
///        Term-side access control — providing no incremental coverage over the unit-test
///        suite (`TermFinanceBidFuseTest`).
///      - Full `Collateral → Bid → BidReveal → clearing → Repurchase` lifecycle. Requires
///        an alpha-controlled auction cycle that is impossible to construct against frozen
///        mainnet state without privileged Term-side actors (auctioneer permission to call
///        `completeAuction`). This full lifecycle is the
///        aspirational target; the realistic substitute is the per-fuse smoke matrix above
///        combined with `testForkBalanceFuseFullLifecycleHappyPath`.
/// @dev Test-only probe interface for the two `TermRepoCollateralManager` functions that are
///      intentionally absent from the production `IExtTermRepoCollateralManager` (they are
///      privileged-caller mutators, not NAV reads). Used by
///      `testForkAuctionLockedCollateralExcludedFromLedgerPreClearing` to drive the live CM
///      across the auction-lock -> journal (clearing) handoff.
interface ICmAuctionProbe {
    /// @dev `onlyRole(AUCTION_LOCKER)` on the live CM (granted to the bid locker). Moves
    ///      collateral into the `TermRepoLocker` escrow; does NOT write `lockedCollateralLedger`.
    function auctionLockCollateral(address sender, address collateralToken, uint256 amount) external;

    /// @dev `onlyRole(SERVICER_ROLE)` on the live CM (granted to the servicer). The ONLY
    ///      ledger write on the standard bid path -- invoked from `TermRepoServicer.fulfillBid`
    ///      at clearing.
    function journalBidCollateralToCollateralManager(
        address borrower,
        address[] calldata collateralTokenAddresses,
        uint256[] calldata collateralTokenAmounts
    ) external;
}

contract TermFinanceBorrowerFork is Test {
    // ----------------------------------------------------------------------
    // Evergreen Ethereum mainnet addresses verified at block 25097999.
    // ----------------------------------------------------------------------
    address private constant TERM_CONTROLLER = 0x21FC7B250CCAeECDb2abb38e04617D1f24D98772;
    address private constant ADAPTER_B = 0x3C6b0398eEd7dAfcb3C13d482400329a6e25Acd2;
    address private constant SERVICER = 0x11951C559cBA31E83f8032cFF4bd854eA0228657;
    address private constant REPO_TOKEN = 0x347220087c69656AD3590200E1ea4Eafe842FD2E;
    address private constant TERM_REPO_LOCKER = 0xb3565AD9ABdE6BFCdc0a8BB28C890329B938B545;
    address private constant COLLATERAL_MANAGER = 0x9b00ee0b1cE01f74B1d18fAc682D4c9A3077C7d3;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant PT_REUSD = 0x3EAA0F0f0A5d3D595ae4e4b0D27f439d01c3E7b2;
    address private constant LIVE_BIDLOCKER = 0x4d28F2722b6288Fd0D6F4320fE2Ab4d347448673;

    // Live borrower with an active obligation at block 25097999 (verified on-chain).
    address private constant LIVE_BORROWER = 0x3976747B82316020A15662761C82860B9785e7f3;

    uint256 private constant MARKET_ID = 49;
    uint256 private constant FORK_BLOCK = 25097999;

    /// @dev WithdrawManager ERC-7201 storage slot used by `PlasmaVaultStorageLib`.
    bytes32 private constant WITHDRAW_MANAGER_SLOT = 0x465d2ff0062318fe6f4c7e9ac78cfcd70bc86a1d992722875ef83a9770513100;
    address private constant WITHDRAW_MANAGER = address(0xBEEF);

    // The mock oracle is deployed once and shared across tests via etch. The harness
    // contracts are etched at LIVE_BORROWER per-test (one harness role per test).
    MockOracle private oracle;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);

        // Tiny mock oracle: USDC = $1 / PT-reUSD = $1 (PT-reUSD is a principal token with
        // par redemption to USDC equivalent; using $1 keeps PV math tractable and avoids a
        // production-oracle dependency).
        oracle = new MockOracle();
        oracle.setAssetPrice(USDC, 1e8, 8);
        oracle.setAssetPrice(PT_REUSD, 1e8, 8);
    }

    // ----------------------------------------------------------------------
    // Helpers
    // ----------------------------------------------------------------------

    function _setWithdrawManager(address harness_, address manager_) private {
        vm.store(harness_, WITHDRAW_MANAGER_SLOT, bytes32(uint256(uint160(manager_))));
    }

    /// @notice Etch the bytecode of a freshly-deployed `TermFinanceCollateralFuseHarness`
    ///         at `LIVE_BORROWER` and configure substrate allowlist + WithdrawManager.
    function _etchCollateralHarnessAtLiveBorrower() private returns (TermFinanceCollateralFuseHarness) {
        TermFinanceCollateralFuseHarness shadow = new TermFinanceCollateralFuseHarness(MARKET_ID, TERM_CONTROLLER);
        vm.etch(LIVE_BORROWER, address(shadow).code);

        bytes32[] memory subs = new bytes32[](2);
        subs[0] = PlasmaVaultConfigLib.addressToBytes32(SERVICER);
        subs[1] = TermFinanceSubstrateLib.collateralPairKey(SERVICER, PT_REUSD);
        TermFinanceCollateralFuseHarness(LIVE_BORROWER).setMarketSubstrates(MARKET_ID, subs);
        _setWithdrawManager(LIVE_BORROWER, WITHDRAW_MANAGER);

        return TermFinanceCollateralFuseHarness(LIVE_BORROWER);
    }

    /// @notice Etch the bytecode of a freshly-deployed `TermFinanceBalanceFuseHarness` at
    ///         `LIVE_BORROWER` and configure substrate allowlist + oracle.
    function _etchBalanceHarnessAtLiveBorrower() private returns (TermFinanceBalanceFuseHarness) {
        TermFinanceBalanceFuseHarness shadow = new TermFinanceBalanceFuseHarness(MARKET_ID, TERM_CONTROLLER, ADAPTER_B);
        vm.etch(LIVE_BORROWER, address(shadow).code);

        bytes32[] memory subs = new bytes32[](2);
        subs[0] = PlasmaVaultConfigLib.addressToBytes32(SERVICER);
        subs[1] = TermFinanceSubstrateLib.collateralPairKey(SERVICER, PT_REUSD);

        TermFinanceBalanceFuseHarness(LIVE_BORROWER).setMarketSubstrates(MARKET_ID, subs);
        TermFinanceBalanceFuseHarness(LIVE_BORROWER).setPriceOracleMiddleware(address(oracle));

        return TermFinanceBalanceFuseHarness(LIVE_BORROWER);
    }

    /// @notice Etch the bytecode of a freshly-deployed `TermFinanceRepurchaseFuseHarness`
    ///         at `LIVE_BORROWER`.
    function _etchRepurchaseHarnessAtLiveBorrower() private returns (TermFinanceRepurchaseFuseHarness) {
        TermFinanceRepurchaseFuseHarness shadow = new TermFinanceRepurchaseFuseHarness(MARKET_ID, TERM_CONTROLLER);
        vm.etch(LIVE_BORROWER, address(shadow).code);

        bytes32[] memory subs = new bytes32[](1);
        subs[0] = PlasmaVaultConfigLib.addressToBytes32(SERVICER);
        TermFinanceRepurchaseFuseHarness(LIVE_BORROWER).setMarketSubstrates(MARKET_ID, subs);
        _setWithdrawManager(LIVE_BORROWER, WITHDRAW_MANAGER);

        return TermFinanceRepurchaseFuseHarness(LIVE_BORROWER);
    }

    // ----------------------------------------------------------------------
    // Sanity / preconditions
    // ----------------------------------------------------------------------

    /// @notice Smoke check that the borrower-flow preconditions assumed by each test still
    ///         hold at the pinned block. Documents the on-chain verification fingerprint inline.
    function testForkPreconditionsHoldAtPinnedBlock() public view {
        // Repurchase window must be open so `RepurchaseFuse._assertWindowOpen` passes.
        uint256 endOfRepurchase = IExtTermRepoServicer(SERVICER).endOfRepurchaseWindow();
        assertGt(endOfRepurchase, block.timestamp, "repurchase window must be open");

        // Live borrower position (verified on-chain) — sanity check the live data exists.
        uint256 obligation = IExtTermRepoServicer(SERVICER).getBorrowerRepurchaseObligation(LIVE_BORROWER);
        assertEq(obligation, 1_009_852_430_555, "live borrower obligation matches plan section 12");

        uint256 liveCollateral =
            IExtTermRepoCollateralManager(COLLATERAL_MANAGER).getCollateralBalance(LIVE_BORROWER, PT_REUSD);
        assertEq(liveCollateral, 1_163_347_104_549, "live borrower collateral matches plan section 12");

        // CollateralManager accepted-token surface (verified on-chain).
        assertEq(
            IExtTermRepoCollateralManager(COLLATERAL_MANAGER).numOfAcceptedCollateralTokens(),
            1,
            "1 accepted collateral token"
        );
        assertEq(IExtTermRepoCollateralManager(COLLATERAL_MANAGER).collateralTokens(0), PT_REUSD, "PT-reUSD is index 0");

        // Active BidLocker is past its revealTime at this block (auction cycle #2 closed
        // around 2026-04-12 — verified on-chain). This is the load-bearing reason the bid +
        // reveal lifecycle is skipped in this suite, see contract NatSpec.
        uint256 revealTime = IExtTermAuctionBidLocker(LIVE_BIDLOCKER).revealTime();
        assertLt(revealTime, block.timestamp, "BidLocker at pinned block is post-reveal");

        // ABI sanity (sub-shape of `TermFinanceLiveBalanceFork.test_liveAbis_areCompatible`)
        assertTrue(IExtTermController(TERM_CONTROLLER).isTermDeployed(SERVICER), "servicer is term-deployed");
        assertEq(IExtTermRepoServicer(SERVICER).termRepoLocker(), TERM_REPO_LOCKER, "termRepoLocker pairing");
        assertEq(
            IExtTermRepoServicer(SERVICER).termRepoCollateralManager(),
            COLLATERAL_MANAGER,
            "termRepoCollateralManager pairing"
        );
    }

    // ----------------------------------------------------------------------
    // CollateralFuse — top-up + draw-down against the live position.
    // ----------------------------------------------------------------------

    /// @notice Top up collateral and draw it back down against the live Term Finance
    ///         CollateralManager.
    /// @dev `externalLockCollateral` requires `getBorrowerRepurchaseObligation(msg.sender)
    ///      != 0` (verified on `0x6a2e09f23ef3a1f5eced9d4daed3b27d181f93e1`). Etching the
    ///      collateral harness at `LIVE_BORROWER` satisfies this precondition with the
    ///      borrower's real ~1.01M USDC obligation. The unlock direction is gated by the
    ///      maintenance-margin invariant which the test respects by only unlocking the
    ///      amount we just topped up.
    function testForkCollateralFuseTopsUpAndDrawsDownOnLiveCollateralManager() public {
        TermFinanceCollateralFuseHarness harness = _etchCollateralHarnessAtLiveBorrower();
        uint256 topUpAmount = 50_000 * 1e6; // 50k PT-reUSD (6 dec)

        uint256 cmBalanceBefore =
            IExtTermRepoCollateralManager(COLLATERAL_MANAGER).getCollateralBalance(LIVE_BORROWER, PT_REUSD);
        deal(PT_REUSD, LIVE_BORROWER, topUpAmount);

        // Top up.
        harness.enter(
            TermFinanceCollateralFuseEnterData({
                servicer: SERVICER,
                collateralManager: COLLATERAL_MANAGER,
                collateralToken: PT_REUSD,
                amount: topUpAmount
            })
        );

        uint256 cmBalanceAfterLock =
            IExtTermRepoCollateralManager(COLLATERAL_MANAGER).getCollateralBalance(LIVE_BORROWER, PT_REUSD);
        assertEq(cmBalanceAfterLock, cmBalanceBefore + topUpAmount, "lock added topUpAmount");
        assertEq(IERC20(PT_REUSD).balanceOf(LIVE_BORROWER), 0, "lock drained borrower wallet");

        // Draw down ONLY what we just added (preserves maintenance margin on the live debt).
        harness.exit(
            TermFinanceCollateralFuseExitData({
                servicer: SERVICER,
                collateralManager: COLLATERAL_MANAGER,
                collateralToken: PT_REUSD,
                amount: topUpAmount
            })
        );

        uint256 cmBalanceAfterUnlock =
            IExtTermRepoCollateralManager(COLLATERAL_MANAGER).getCollateralBalance(LIVE_BORROWER, PT_REUSD);
        assertEq(cmBalanceAfterUnlock, cmBalanceBefore, "unlock returned to pre-test CM balance");
        assertEq(IERC20(PT_REUSD).balanceOf(LIVE_BORROWER), topUpAmount, "unlock restored borrower wallet");
    }

    // ----------------------------------------------------------------------
    // RepurchaseFuse — settle a partial debt on the live servicer.
    // ----------------------------------------------------------------------

    /// @notice Submit a partial repurchase payment against the live borrower obligation.
    /// @dev `submitRepurchasePayment` pulls USDC via `TermRepoLocker.transferTokenFromWallet`
    ///      (verified surface — see `IExtTermRepoServicer.submitRepurchasePayment` NatSpec).
    ///      The fuse approves the locker, calls the servicer, and measures the actual delta
    ///      pulled to emit a faithful event. We assert: (a) the USDC balance was pulled,
    ///      (b) the obligation decreased.
    function testForkRepurchaseFuseSettlesDebtOnLiveServicer() public {
        TermFinanceRepurchaseFuseHarness harness = _etchRepurchaseHarnessAtLiveBorrower();

        uint256 obligationBefore = IExtTermRepoServicer(SERVICER).getBorrowerRepurchaseObligation(LIVE_BORROWER);
        assertGt(obligationBefore, 0, "live borrower must have obligation");

        // Fund the borrower with USDC sufficient for a half repay.
        uint256 repayAmount = obligationBefore / 2;
        deal(USDC, LIVE_BORROWER, repayAmount);

        uint256 usdcBefore = IERC20(USDC).balanceOf(LIVE_BORROWER);
        assertEq(usdcBefore, repayAmount, "borrower USDC funded");

        harness.enter(TermFinanceRepurchaseFuseEnterData({servicer: SERVICER, amount: repayAmount}));

        uint256 usdcAfter = IERC20(USDC).balanceOf(LIVE_BORROWER);
        uint256 obligationAfter = IExtTermRepoServicer(SERVICER).getBorrowerRepurchaseObligation(LIVE_BORROWER);

        // The Servicer pulls exactly `repayAmount` on a partial repay (the cap only applies
        // when amount > obligation). The fuse's pre/post delta measurement is exercised
        // here; the test verifies the live call moved real USDC and decreased the obligation.
        assertEq(usdcBefore - usdcAfter, repayAmount, "vault USDC drained by repayAmount");
        assertLt(obligationAfter, obligationBefore, "obligation decreased");
    }

    // ----------------------------------------------------------------------
    // BalanceFuse — live multi-leg aggregation.
    // ----------------------------------------------------------------------

    /// @notice The live borrower has BOTH a real collateral position (~1.16M PT-reUSD) AND
    ///         a real outstanding obligation (~1.01M USDC FACE). `balanceOf` must aggregate
    ///         both the collateral leg (positive) and the discounted debt leg (negative),
    ///         producing a non-zero net value priced through the mock oracle at $1 each.
    function testForkBalanceFuseAggregatesAllLegsCorrectly() public {
        TermFinanceBalanceFuseHarness harness = _etchBalanceHarnessAtLiveBorrower();

        uint256 nav = harness.balanceOf();
        assertGt(nav, 0, "NAV > 0 (collateral PV > debt PV at ~109.29% maint ratio)");

        // Manual approximate calculation:
        //   collateralValue   = 1_163_347_104_549 * 1e8 / 1e14 = 1_163_347.10 WAD-USD
        //   obligationFace    = 1_009_852_430_555 raw USDC
        //   PV of debt        ≈ face * 1e6 / (1e6 + rate * secondsToMaturity / 360d)
        //   For a positive rate, PV(debt) < face. The exact rate from Adapter-B at this
        //   block governs the PV; we sanity-check the sign and the order of magnitude.
        uint256 collateralFaceWad = (1_163_347_104_549 * 1e18) / 1e6;
        uint256 obligationFaceWad = (1_009_852_430_555 * 1e18) / 1e6;
        assertGt(nav, 0, "net NAV positive");
        // NAV is bounded above by collateral and bounded below by collateral - obligation
        // FACE (because PV(debt) ≤ face).
        assertLt(nav, collateralFaceWad + 1, "NAV bounded above by collateral");
        assertGt(nav + obligationFaceWad, collateralFaceWad - 1, "NAV bounded below by collateral - face");
    }

    /// @notice When the vault has a tracked pending bid but the debt-read mocks a revert,
    ///         `balanceOf` MUST re-raise `TermFinanceBalanceFuseDebtReadFailedForTrackedServicer`.
    /// @dev The gate is documented in `TermFinanceBalanceFuse._debtValueWadForServicer`.
    ///      The live borrower's tracked exposure comes from the real `getCollateralBalance`
    ///      reading positive, so the priorCollateralValue > 0 path is exercised.
    function testForkBalanceFuseDebtReadGatedByTrackedExposure() public {
        TermFinanceBalanceFuseHarness harness = _etchBalanceHarnessAtLiveBorrower();

        // Mock the live Servicer's debt read to revert.
        vm.mockCallRevert(
            SERVICER,
            abi.encodeWithSelector(IExtTermRepoServicer.getBorrowerRepurchaseObligation.selector, LIVE_BORROWER),
            "DEBT_READ_REVERTS"
        );

        vm.expectRevert(
            abi.encodeWithSignature("TermFinanceBalanceFuseDebtReadFailedForTrackedServicer(address)", SERVICER)
        );
        harness.balanceOf();

        vm.clearMockedCalls();
    }

    /// @notice `balanceOf` must remain staticcall-safe even on a position with both
    ///         collateral and debt legs reading live Term Finance proxies.
    function testForkBalanceFuseStaticcallSafe() public {
        TermFinanceBalanceFuseHarness harness = _etchBalanceHarnessAtLiveBorrower();

        (bool ok, bytes memory ret) = address(harness).staticcall(abi.encodeWithSignature("balanceOf()"));
        assertTrue(ok, "balanceOf must be staticcall-safe against live proxies");
        uint256 nav = abi.decode(ret, (uint256));
        assertGt(nav, 0, "non-zero NAV under staticcall");
    }

    /// @notice The oracle policy is "owner-controlled config; missing prices are NAV-blocking
    ///         on TRACKED servicers". The live borrower at the pinned block
    ///         has positive locked PT-reUSD collateral AND a positive USDC debt obligation —
    ///         clearly tracked. When PT-reUSD's oracle is wiped, the locked-collateral leg
    ///         pricer (`_priceTokenAmountWadGuarded`) returns `(false, 0)`, the per-servicer
    ///         aggregator detects tracked exposure (via `hasLocked == true`) and re-raises
    ///         `TermFinanceBalanceFusePurchaseTokenPriceZeroForTracked(SERVICER)`.
    /// @dev The mock oracle's underlying `UnsupportedQuoteCurrencyFromOracle` selector is
    ///      NOT seen by the fuse here — the fuse routes through the IPOR oracle middleware
    ///      adapter, which returns `(0, 0)` for unknown entries (because the mock's
    ///      `setAssetPrice(PT_REUSD, 0, 0)` explicitly STORES `price == 0`); the fuse's
    ///      tracked gate re-raises with its own diagnostic error before any underlying
    ///      oracle revert. Untracked variant: see
    ///      `testBalanceFuseDegradesLegToZeroWhenPurchaseTokenPriceIsZero_untracked` in the
    ///      unit suite.
    function testForkBalanceFuseHandlesOracleMissingOnCollateral() public {
        // Defensive: confirm LIVE_BORROWER is genuinely tracked before testing the re-raise
        // path. Without this, a future fork-block change that closes the position would
        // silently change the test's failure mode from "revert" to "nav == 0", masking a
        // regression in the tracked-vs-untracked gate.
        assertGt(
            IExtTermRepoCollateralManager(COLLATERAL_MANAGER).getCollateralBalance(LIVE_BORROWER, PT_REUSD),
            0,
            "tracked precondition: locked collateral"
        );
        assertGt(
            IExtTermRepoServicer(SERVICER).getBorrowerRepurchaseObligation(LIVE_BORROWER),
            0,
            "tracked precondition: positive obligation"
        );

        TermFinanceBalanceFuseHarness harness = _etchBalanceHarnessAtLiveBorrower();
        oracle.setAssetPrice(PT_REUSD, 0, 0);

        // Live borrower has tracked exposure (locked PT-reUSD collateral). The
        // fuse re-raises with its own diagnostic error rather than letting the oracle's
        // revert bubble.
        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBalanceFuse.TermFinanceBalanceFusePurchaseTokenPriceZeroForTracked.selector, SERVICER
            )
        );
        harness.balanceOf();
    }

    /// @notice Full happy-path lifecycle on the live position: lock additional collateral,
    ///         partial repurchase, then unlock that additional collateral. Asserts the
    ///         BalanceFuse NAV evolution and that no state inconsistencies arise.
    /// @dev This is the closest substitute for the full lifecycle that can be
    ///      run against frozen mainnet state without a live auction (which would require
    ///      auctioneer-permission `completeAuction`). Exercises Collateral.enter + exit
    ///      AND Repurchase.enter in sequence, with the BalanceFuse NAV read sandwiched in
    ///      between as a post-condition check.
    function testForkBalanceFuseFullLifecycleHappyPath() public {
        // ============ Step 1: snapshot pre-test state ============
        uint256 collateralBefore =
            IExtTermRepoCollateralManager(COLLATERAL_MANAGER).getCollateralBalance(LIVE_BORROWER, PT_REUSD);
        uint256 obligationBefore = IExtTermRepoServicer(SERVICER).getBorrowerRepurchaseObligation(LIVE_BORROWER);

        // ============ Step 2: lock additional collateral ============
        TermFinanceCollateralFuseHarness collHarness = _etchCollateralHarnessAtLiveBorrower();
        uint256 topUpAmount = 50_000 * 1e6;
        deal(PT_REUSD, LIVE_BORROWER, topUpAmount);
        collHarness.enter(
            TermFinanceCollateralFuseEnterData({
                servicer: SERVICER,
                collateralManager: COLLATERAL_MANAGER,
                collateralToken: PT_REUSD,
                amount: topUpAmount
            })
        );

        uint256 collateralAfterLock =
            IExtTermRepoCollateralManager(COLLATERAL_MANAGER).getCollateralBalance(LIVE_BORROWER, PT_REUSD);
        assertEq(collateralAfterLock, collateralBefore + topUpAmount, "collateral topped up");

        // ============ Step 3: partial repurchase ============
        TermFinanceRepurchaseFuseHarness repHarness = _etchRepurchaseHarnessAtLiveBorrower();
        uint256 repayAmount = obligationBefore / 4;
        deal(USDC, LIVE_BORROWER, repayAmount);
        repHarness.enter(TermFinanceRepurchaseFuseEnterData({servicer: SERVICER, amount: repayAmount}));

        uint256 obligationAfterRepay = IExtTermRepoServicer(SERVICER).getBorrowerRepurchaseObligation(LIVE_BORROWER);
        assertLt(obligationAfterRepay, obligationBefore, "obligation decreased on repurchase");

        // ============ Step 4: balanceOf reflects the new state ============
        TermFinanceBalanceFuseHarness balHarness = _etchBalanceHarnessAtLiveBorrower();
        uint256 navMid = balHarness.balanceOf();
        assertGt(navMid, 0, "NAV positive after partial repurchase + topup");

        // ============ Step 5: draw down the additional collateral we added ============
        collHarness = _etchCollateralHarnessAtLiveBorrower();
        collHarness.exit(
            TermFinanceCollateralFuseExitData({
                servicer: SERVICER,
                collateralManager: COLLATERAL_MANAGER,
                collateralToken: PT_REUSD,
                amount: topUpAmount
            })
        );

        uint256 collateralAfterUnlock =
            IExtTermRepoCollateralManager(COLLATERAL_MANAGER).getCollateralBalance(LIVE_BORROWER, PT_REUSD);
        assertEq(collateralAfterUnlock, collateralBefore, "collateral drained back to baseline");

        // ============ Step 6: final NAV sanity ============
        balHarness = _etchBalanceHarnessAtLiveBorrower();
        uint256 navFinal = balHarness.balanceOf();
        assertGt(navFinal, 0, "NAV remains positive after full lifecycle");
    }

    // ----------------------------------------------------------------------
    // Regression — post-clearing locker zero-struct invariant.
    // ----------------------------------------------------------------------

    /// @notice Pin the on-chain invariant that backs `_tryReadLockedBidIsLive`'s predicate
    ///         (`bid.bidder != address(0) && bid.amount != 0`) on a real, completed Term
    ///         Finance auction.
    /// @dev Rules out a potential bid-collateral double-count between
    ///      `TermAuction.completeAuction` and our `TermFinanceCleanupFuse` run. Such a
    ///      double-count would presume a window in which the BidLocker storage entry is still non-zero
    ///      AND the orchestrator already flipped `auctionCompleted = true`. Per the
    ///      vendored Term Finance v0.9.0 source (impl
    ///      `0xEC2125566ee98761d0605E42B0c3b2adeB051007`,
    ///      `TermAuctionBidLocker._processBidForAuction` lines 959-962):
    ///
    ///          function _processBidForAuction(bytes32 id) internal {
    ///              delete bids[id];
    ///              bidCount -= 1;
    ///          }
    ///
    ///      Every clearing path inside `_getAllBids` (expired-rollover :616,
    ///      revealed-shortfall :736, revealed-assigned :941, unrevealed :658) routes
    ///      through this delete; at the end `assert(bidCount == 0)` (:668) holds, so the
    ///      entire `bids` mapping is empty post-completion. `TermAuction.completeAuction`
    ///      flips `auctionCompleted = true` (`TermAuction.sol:213`) and immediately calls
    ///      `getAllBids` (`TermAuction.sol:231`) inside the SAME external transaction —
    ///      no observable window exists where the two facts disagree.
    ///
    ///      Pinned-fork evidence: at block 25097999 (post-`auctionEndTime` for the live
    ///      `LIVE_BIDLOCKER` cycle) we observe `auctionCompleted == true` on the paired
    ///      `TermAuction` orchestrator (`0xD69C75030b4962c642585AC080B40c815EaFb27E`) AND
    ///      every probe of `lockedBid(id)` returns a fully zero-valued struct. The
    ///      `BidLocked` event topic
    ///      `0x883435c56acd8a7f195790129e33085f436925ef33028c425097430c41c9a763` returned
    ///      ZERO matches across the entire locker lifetime at the pinned block (the
    ///      locker was first activated at block 24888170 — earlier than the fork — and
    ///      no auction-cycle bids were ever submitted before clearing). Consequently
    ///      every `lockedBid(id)` read at this block is by definition a "post-clearing
    ///      OR never-existed" read, both of which are the SAME memory state (the
    ///      defaulted slot). We probe several representative ids — a zero id, an id
    ///      derived from a borrower address via the `_generateBidId(seed, user)` keccak
    ///      pattern (`TermAuctionBidLocker.sol:946-957`), and the actual `LIVE_BORROWER`
    ///      address-derived id — and assert the struct is fully zero for every probe.
    ///
    ///      The third sub-assertion (bid-leg contributes 0 to NAV) plugs a synthetic
    ///      `TermFinancePendingBidsStorageLib` entry referencing the live locker and a
    ///      cleared id, then reads `balanceOf` to observe that the predicate gates the
    ///      bid leg even though storage is not yet pruned (`TermFinanceCleanupFuse` not
    ///      yet run). This is the exact double-count scenario — and we
    ///      observe it does NOT occur.
    function testForkLockedBidReturnsAllZeroAtCompletedAuction() external {
        // ---- Sub-assertion 1: locker.termAuction().auctionCompleted() == true ----
        // Confirm we are observing a genuinely completed auction at the fork block.
        // `termAuction()` exists on the locker proxy but is not in IExtTermAuctionBidLocker
        // (we only need it transiently for this regression probe — raw staticcall keeps
        // the production interface minimal).
        (bool okTermAuction, bytes memory retTermAuction) =
            LIVE_BIDLOCKER.staticcall(abi.encodeWithSignature("termAuction()"));
        assertTrue(okTermAuction, "locker.termAuction() must be staticcall-safe");
        address termAuction = abi.decode(retTermAuction, (address));
        assertTrue(termAuction != address(0), "locker.termAuction() must be non-zero");
        (bool okCompleted, bytes memory retCompleted) =
            termAuction.staticcall(abi.encodeWithSignature("auctionCompleted()"));
        assertTrue(okCompleted, "termAuction.auctionCompleted() must be staticcall-safe");
        bool auctionCompleted = abi.decode(retCompleted, (bool));
        assertTrue(auctionCompleted, "auction must be completed at pinned block");

        // ---- Sub-assertion 2: lockedBid(id) returns the all-zero struct ----
        // Probe a representative basket of ids. The locker's `bids` mapping returns the
        // defaulted struct for both "never existed" and "cleared by _processBidForAuction".
        // Since the auction is completed, ANY id that was ever active has been deleted;
        // ids that never existed are also defaulted. Both states are indistinguishable
        // by `lockedBid`, which is the invariant this test pins.
        bytes32[3] memory probeIds = [
            bytes32(0),
            // Deterministic id derived from LIVE_BORROWER via the locker's own
            // `_generateBidId(seed, user)` pattern: keccak256(abi.encodePacked(seed, user,
            // locker)). Using seed = 0x01 keeps it reproducible.
            keccak256(abi.encodePacked(bytes32(uint256(1)), LIVE_BORROWER, LIVE_BIDLOCKER)),
            // A non-zero arbitrary id for breadth.
            keccak256("TF-H-3 regression probe")
        ];

        for (uint256 i; i < probeIds.length; ++i) {
            IExtTermAuctionBidLocker.TermAuctionBid memory b =
                IExtTermAuctionBidLocker(LIVE_BIDLOCKER).lockedBid(probeIds[i]);
            assertEq(b.id, bytes32(0), "id must be zero post-clearing");
            assertEq(b.bidder, address(0), "bidder must be zero post-clearing");
            assertEq(b.bidPriceHash, bytes32(0), "bidPriceHash must be zero post-clearing");
            assertEq(b.bidPriceRevealed, 0, "bidPriceRevealed must be zero post-clearing");
            assertEq(b.amount, 0, "amount must be zero post-clearing");
            assertEq(b.collateralAmounts.length, 0, "collateralAmounts must be empty");
            assertEq(b.purchaseToken, address(0), "purchaseToken must be zero");
            assertEq(b.collateralTokens.length, 0, "collateralTokens must be empty");
            assertEq(b.isRollover, false, "isRollover must be false");
            assertEq(b.rolloverPairOffTermRepoServicer, address(0), "rolloverPair must be zero");
            assertEq(b.isRevealed, false, "isRevealed must be false");
        }

        // ---- Sub-assertion 3: BalanceFuse bid-leg contributes 0 even with a stored,
        // un-pruned pending-bid entry pointing at a cleared id. This is the exact
        // double-count scenario: storage says "we have a pending bid against
        // servicer X for collateral C", but the locker says "the bid is cleared". The
        // predicate inside `_tryReadLockedBidIsLive` MUST gate the bid leg to zero;
        // `TermFinanceCleanupFuse` then prunes the vault-side storage later.
        TermFinanceBalanceFuseHarness harness = _etchBalanceHarnessAtLiveBorrower();

        // Snapshot NAV with no pending-bid entries — this is the "control" reading; only
        // the live collateral and debt legs contribute.
        uint256 navWithoutSyntheticBid = harness.balanceOf();

        // Plug a synthetic pending-bid entry that points at the LIVE locker and a
        // cleared id, with a real collateral basket so a buggy predicate WOULD inflate
        // NAV.
        // Note: the live locker has never emitted `BidLocked` at the pinned block, so this
        // probe exercises the never-locked-id path; the wiped-id path lands in the same
        // defaulted storage slot and is observationally identical from the predicate's
        // perspective (see NatSpec at `TermFinanceBalanceFuse._tryReadLockedBidIsLive` for
        // the soundness argument covering both states).
        address[] memory collateralTokens = new address[](1);
        collateralTokens[0] = PT_REUSD;
        uint256[] memory collateralAmounts = new uint256[](1);
        collateralAmounts[0] = 1_000_000 * 1e6; // 1M PT-reUSD synthetic over-count attempt

        harness.addPendingBid(
            SERVICER,
            LIVE_BIDLOCKER,
            probeIds[1], // cleared / never-existed id
            500_000 * 1e6, // synthetic purchase amount
            collateralTokens,
            collateralAmounts
        );

        uint256 navWithSyntheticBid = harness.balanceOf();

        // The predicate must gate the bid leg to 0 — NAV unchanged versus the control.
        assertEq(
            navWithSyntheticBid,
            navWithoutSyntheticBid,
            "bid leg must contribute 0 when locker entry is zero, regardless of vault-side storage state"
        );
    }

    /// @notice Pin the pre-clearing disjointness invariant on live mainnet
    ///         bytecode: collateral moved by `auctionLockCollateral` during `lockBids`
    ///         (before the auction clears) is NOT reflected in `getCollateralBalance`, and is
    ///         credited to the ledger ONLY by `journalBidCollateralToCollateralManager` at
    ///         clearing. This is the pre-clearing sibling of the post-clearing invariant.
    /// @dev Source proof (term-finance-contracts @ 306bb3a):
    ///        - `getCollateralBalance` reads `lockedCollateralLedger` (TermRepoCollateralManager.sol:668-673).
    ///        - `auctionLockCollateral` is transfer-only, no ledger write (CM.sol:692-698);
    ///          the `lockedCollateralLedger +=` at CM.sol:731 belongs to `acceptRolloverCollateral`
    ///          (rollover path), not this one.
    ///        - `journalBidCollateralToCollateralManager` is the only standard-bid ledger write
    ///          (CM.sol:802-816), called from `TermRepoServicer.fulfillBid` at clearing.
    ///        - `TermAuctionBidLocker._lock` (standard bid) calls `auctionLockCollateral`
    ///          (TermAuctionBidLocker.sol:532,547); rollover is a separate, fuse-unreachable path.
    ///      Why this shape (not a live `lockBids`): at block 25097999 `revealTime` has passed
    ///      (asserted by the preconditions test), so `lockBids`' `onlyWhileAuctionOpen` would
    ///      revert; bypassing it requires mocking the code under test. Driving the live CM
    ///      directly via the real `AUCTION_LOCKER` (the bid locker) exercises the exact
    ///      production ledger path without any mock.
    function testForkAuctionLockedCollateralExcludedFromLedgerPreClearing() external {
        ICmAuctionProbe cm = ICmAuctionProbe(COLLATERAL_MANAGER);

        // Sanity: PT_REUSD must be an accepted collateral token on this CM, else the probe
        // would be meaningless.
        uint8 acceptedCount = IExtTermRepoCollateralManager(COLLATERAL_MANAGER).numOfAcceptedCollateralTokens();
        bool ptAccepted;
        for (uint256 i; i < acceptedCount; ++i) {
            if (IExtTermRepoCollateralManager(COLLATERAL_MANAGER).collateralTokens(i) == PT_REUSD) {
                ptAccepted = true;
            }
        }
        assertTrue(ptAccepted, "PT_REUSD must be an accepted collateral token at the pinned block");

        // Fresh vault-like borrower with no prior Term position -> ledger starts at 0.
        address vault = address(0x000000000000000000000000000000000000fA17);
        uint256 amount = 1_000 * 1e6; // PT-reUSD is 6-dec (see lender fork test)

        // Fund the vault and approve the TermRepoLocker (the pull target inside auctionLockCollateral).
        deal(PT_REUSD, vault, amount);
        vm.prank(vault);
        IERC20(PT_REUSD).approve(TERM_REPO_LOCKER, amount);

        uint256 ledgerBefore = IExtTermRepoCollateralManager(COLLATERAL_MANAGER).getCollateralBalance(vault, PT_REUSD);
        assertEq(ledgerBefore, 0, "fresh borrower: ledger starts at 0");

        // ---- Pre-clearing auction lock, by the real AUCTION_LOCKER (the bid locker) ----
        vm.prank(LIVE_BIDLOCKER);
        cm.auctionLockCollateral(vault, PT_REUSD, amount);

        // DISJOINTNESS (the invariant): auction-lock must NOT credit the ledger that
        // `getCollateralBalance` reads. If a future CM upgrade started crediting at lock time,
        // this assertion fails and flags the re-introduced double-count.
        uint256 ledgerAfterAuctionLock =
            IExtTermRepoCollateralManager(COLLATERAL_MANAGER).getCollateralBalance(vault, PT_REUSD);
        assertEq(
            ledgerAfterAuctionLock,
            ledgerBefore,
            "auctionLockCollateral must NOT touch lockedCollateralLedger (pre-clearing disjointness)"
        );

        // The collateral physically moved into the locker escrow (proves the lock happened).
        assertEq(IERC20(PT_REUSD).balanceOf(vault), 0, "collateral pulled into TermRepoLocker escrow");

        // ---- Clearing handoff: journal IS the ledger write ----
        address[] memory tokens = new address[](1);
        tokens[0] = PT_REUSD;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        vm.prank(SERVICER);
        cm.journalBidCollateralToCollateralManager(vault, tokens, amounts);

        uint256 ledgerAfterJournal =
            IExtTermRepoCollateralManager(COLLATERAL_MANAGER).getCollateralBalance(vault, PT_REUSD);
        assertEq(
            ledgerAfterJournal,
            ledgerBefore + amount,
            "journal credits the ledger at clearing (handoff completes; no double-count window)"
        );
    }
}

// --------------------------------------------------------------------------
// Minimal mock oracle — same shape as `TermFinanceLiveBalanceFork.MockOracle`
// but reverts with `UnsupportedQuoteCurrencyFromOracle` on a wiped entry to
// mirror the production `PriceOracleMiddleware` behaviour.
// --------------------------------------------------------------------------

contract MockOracle {
    mapping(address => uint256) private _price;
    mapping(address => uint256) private _dec;

    function setAssetPrice(address asset_, uint256 price_, uint256 dec_) external {
        _price[asset_] = price_;
        _dec[asset_] = dec_;
    }

    function getAssetPrice(address asset_) external view returns (uint256, uint256) {
        uint256 p = _price[asset_];
        if (p == 0) revert Errors.UnsupportedQuoteCurrencyFromOracle();
        return (p, _dec[asset_]);
    }
}

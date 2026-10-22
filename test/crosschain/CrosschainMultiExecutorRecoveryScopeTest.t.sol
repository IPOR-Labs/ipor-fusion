// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, stdError} from "forge-std/Test.sol";

import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {
    CrosschainClaimFuse,
    CrosschainClaimFuseEnterData
} from "../../contracts/fuses/crosschain/CrosschainClaimFuse.sol";
import {CrosschainBalanceFuse} from "../../contracts/fuses/crosschain/CrosschainBalanceFuse.sol";
import {CrosschainSubstrateLib} from "../../contracts/fuses/crosschain/lib/CrosschainSubstrateLib.sol";
import {CrosschainRecoveryLib} from "../../contracts/fuses/crosschain/lib/CrosschainRecoveryLib.sol";

import {PlasmaVaultExecuteHarness} from "./CrosschainRecoveryBatchScopingTest.t.sol";
import {MockExecutor} from "./mocks/MockExecutor.sol";
import {MockPriceOracleMiddleware} from "./mocks/MockPriceOracleMiddleware.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

/// @notice Thin wrapper exposing the internal recovery-scope API so the marker's scoping can be asserted
///         directly.
/// @dev At library level on purpose. The balance-fuse-level tests below cover the multi-executor case
///      inside one market, but the marker also has to be scoped by MARKET, and reaching a cross-market
///      leak end to end would need a vault harness carrying two CROSSCHAIN markets with one executor
///      each — transient storage is keyed by the vault address, so both markets would have to live on
///      the same harness. The scope check itself is what matters and it is fully observable here.
contract RecoveryScopeHarness {
    function mark(uint256 marketId_, address executor_) external {
        CrosschainRecoveryLib.markRecovery(marketId_, executor_);
    }

    function isRecovery(uint256 marketId_, address executor_) external view returns (bool) {
        return CrosschainRecoveryLib.isRecovery(marketId_, executor_);
    }

    function isRecoveryArmed() external view returns (bool) {
        return CrosschainRecoveryLib.isRecoveryArmed();
    }
}

/// @title CrosschainMultiExecutorRecoveryScopeTest
/// @notice Regression coverage for
///         `cross_transport_recovery_marker_suppresses_fail_closed_gate_and_discards_sibling_executor_nav`.
///
/// The CROSSCHAIN market is designed to hold several EXECUTOR substrates (one per transport — Stargate
/// and CCIP). Two defects met there:
///
/// 1. `CrosschainRecoveryLib`'s marker was one global transient bool, so a recovery driven against the
///    CCIP executor made `CrosschainBalanceFuse.balanceOf()` swallow a fail-closed revert coming from the
///    Stargate executor, which the batch never touched and which is not being repaired.
/// 2. On any `getBalance()` revert the fuse did `return _cachedBalanceValueUsd(...)` from INSIDE its loop.
///    That discards every live value already summed for healthy executors, never reads the ones after it,
///    and substitutes a single pre-transaction market-wide aggregate — which `updateMarketsBalances` then
///    persists as the market's authoritative NAV.
///
/// The marker is now scoped to `(market, executor)`, and the market-wide cache fallback is never used when the
/// market holds more than one executor, because one aggregate cannot be decomposed per executor. Since IL-8611
/// the marked executor alone is valued by its booked `getBalanceUnchecked()` instead, but only for a STALENESS
/// reason: a `ChainBlocked` reason, or an executor whose `getBalanceUnchecked()` reverts `ChainBlocked`, keeps
/// the batch reverting (a blocked chain means known-inconsistent books until a rescue completes).
contract CrosschainMultiExecutorRecoveryScopeTest is Test {
    uint256 internal constant MARKET = IporFusionMarkets.CROSSCHAIN;

    /// @dev Persisted cache covering BOTH executors, as a previous successful NAV update left it.
    uint256 internal constant CACHED_MARKET_VALUE = 2_000e6;
    /// @dev The healthy sibling's live value, which has FALLEN since that snapshot — the direction in
    ///      which substituting the stale aggregate over-reports NAV.
    uint256 internal constant HEALTHY_LIVE = 600e6;
    uint256 internal constant CLAIM = 100e6;

    MockERC20 internal usdc;
    PlasmaVaultExecuteHarness internal vault;
    MockPriceOracleMiddleware internal oracle;

    CrosschainClaimFuse internal claimFuse;
    CrosschainBalanceFuse internal balanceFuse;

    /// @dev Stands in for the Stargate executor: live, fresh, readable.
    MockExecutor internal healthyExecutor;
    /// @dev Stands in for the CCIP executor under repair: `getBalance()` fail-closed (`chainBlocked`).
    MockExecutor internal impairedExecutor;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new PlasmaVaultExecuteHarness(address(usdc), 6, MARKET);

        claimFuse = new CrosschainClaimFuse(MARKET);
        balanceFuse = new CrosschainBalanceFuse(MARKET);
        vault.setFuses(address(claimFuse), address(balanceFuse));

        healthyExecutor = new MockExecutor(address(vault), address(usdc));
        impairedExecutor = new MockExecutor(address(vault), address(usdc));

        bytes32[] memory subs = new bytes32[](2);
        subs[0] = CrosschainSubstrateLib.executorSubstrate(address(healthyExecutor));
        subs[1] = CrosschainSubstrateLib.executorSubstrate(address(impairedExecutor));
        vault.grantSubstrates(subs);

        oracle = new MockPriceOracleMiddleware();
        oracle.setPrice(address(usdc), 1e8, 8);
        vault.setPriceOracleMiddleware(address(oracle));

        healthyExecutor.setBalance(HEALTHY_LIVE);
        usdc.mint(address(impairedExecutor), CACHED_MARKET_VALUE);
        vault.seedMarketBalance(CACHED_MARKET_VALUE);

        impairedExecutor.setBalanceReverts(true);
    }

    // ---------------------------------------------------------------------
    // Marker scoping (mechanic 1)
    // ---------------------------------------------------------------------

    /// @dev A marker armed for one executor must not read as armed for a sibling, nor for the same
    ///      executor on another market. `isRecoveryArmed` stays true for both — it exists only for the
    ///      recovery/new-exposure mutual exclusion, which IS a batch-level property.
    function test_markerIsScopedToTheExecutorAndMarketItWasArmedFor() public {
        RecoveryScopeHarness harness = new RecoveryScopeHarness();
        address executorA = address(0xA11);
        address executorB = address(0xB22);

        harness.mark(MARKET, executorA);

        assertTrue(harness.isRecovery(MARKET, executorA), "armed for the executor under repair");
        assertFalse(harness.isRecovery(MARKET, executorB), "NOT armed for a sibling executor");
        assertFalse(harness.isRecovery(MARKET + 1, executorA), "NOT armed on another market");
        assertTrue(harness.isRecoveryArmed(), "batch-level flag still set for the exposure exclusion");
    }

    // ---------------------------------------------------------------------
    // Cross-transport gate suppression + market-wide substitution (mechanics 1 + 2)
    // ---------------------------------------------------------------------

    /// @dev The finding's scenario, as it behaves since IL-8611 / TP-M-33. A recovery batch is driven against
    ///      the impaired executor only. The healthy sibling is live and its real value has fallen to 600e6,
    ///      while the cache still says 2000e6 for the whole market. The stale aggregate must never be
    ///      substituted (that over-reported NAV and threw the sibling's live value away); instead ONLY the
    ///      marked, stale executor is valued by its booked balance (staleness gates skipped) and the sibling keeps its live
    ///      `getBalance()`, so the recovery is no longer rolled back.
    function test_recoveryInAMultiExecutorMarketSubstitutesOnlyTheMarkedExecutorsUncheckedBalance() public {
        impairedExecutor.setBalance(1_300e6); // booked value after the claim; getBalance() itself stays fail-closed

        vm.expectEmit(address(vault));
        emit CrosschainBalanceFuse.CrosschainUncheckedBalanceServed(
            MARKET, address(impairedExecutor), MockExecutor.NavSettledStale.selector
        );
        vault.executeClaimBatch(CrosschainClaimFuseEnterData({executor: address(impairedExecutor), amount: CLAIM}));

        assertEq(
            vault.cachedMarketBalance(),
            HEALTHY_LIVE + 1_300e6,
            "healthy sibling live + marked executor unchecked, NOT the 2000e6 stale aggregate"
        );
    }

    /// @dev A marked executor whose `getBalance()` reverts `ChainBlocked` is NOT substituted in a multi-executor
    ///      market: the original returndata is rethrown and nothing is persisted (IL-8611 follow-up).
    function test_markedChainBlockedExecutorInAMultiExecutorMarketRethrows() public {
        impairedExecutor.setBalanceBlocked(true);
        impairedExecutor.setBalance(1_300e6);

        vm.expectRevert(abi.encodeWithSelector(MockExecutor.ChainBlocked.selector, uint256(1)));
        vault.executeClaimBatch(CrosschainClaimFuseEnterData({executor: address(impairedExecutor), amount: CLAIM}));

        assertEq(vault.cachedMarketBalance(), CACHED_MARKET_VALUE, "nothing persisted");
    }

    /// @dev The executor refuses the unchecked read while a chain is blocked even though `getBalance()` surfaced a
    ///      staleness selector first: the `ChainBlocked` from `getBalanceUnchecked()` bubbles out of the fuse.
    function test_staleMarkedExecutorWithABlockedChainBubblesUncheckedChainBlocked() public {
        impairedExecutor.setUncheckedBlocked(true); // getBalance() stays NavSettledStale
        impairedExecutor.setBalance(1_300e6);

        vm.expectRevert(abi.encodeWithSelector(MockExecutor.ChainBlocked.selector, uint256(1)));
        vault.executeClaimBatch(CrosschainClaimFuseEnterData({executor: address(impairedExecutor), amount: CLAIM}));

        assertEq(vault.cachedMarketBalance(), CACHED_MARKET_VALUE, "nothing persisted");
    }

    /// @dev The fallback keeps the revert allowlist: a marked executor failing with anything that is not a
    ///      documented fail-closed selector (here a Panic) still reverts in a multi-executor market.
    function test_markedExecutorWithANonFailClosedRevertStillReverts() public {
        impairedExecutor.setBalanceReverts(false);
        impairedExecutor.setFailMode(MockExecutor.FailMode.PANIC, "");
        impairedExecutor.setBalance(1);

        vm.expectRevert(stdError.divisionError);
        vault.executeClaimBatch(CrosschainClaimFuseEnterData({executor: address(impairedExecutor), amount: CLAIM}));
    }

    /// @dev Both executors fail closed but only one is marked: the unmarked one still reverts, so the
    ///      per-executor fallback cannot be used to launder a sibling's gate.
    function test_unmarkedFailClosedSiblingStillRevertsEvenWhenAnotherExecutorIsMarked() public {
        healthyExecutor.setBalanceReverts(true);

        vm.expectRevert(abi.encodeWithSelector(MockExecutor.NavSettledStale.selector, uint256(1)));
        vault.executeClaimBatch(CrosschainClaimFuseEnterData({executor: address(impairedExecutor), amount: CLAIM}));

        assertEq(vault.cachedMarketBalance(), CACHED_MARKET_VALUE, "nothing persisted");
    }

    /// @dev The cross-transport half stated on its own: the marker is armed against the impaired
    ///      executor, and it is the OTHER executor that fails closed. Nothing about the batch entitles
    ///      the healthy sibling's revert to be swallowed.
    function test_recoveryOnOneExecutorDoesNotSwallowASiblingsFailClosedRevert() public {
        // Flip the roles: the executor being repaired reads fine, the sibling is the blocked one.
        impairedExecutor.setBalanceReverts(false);
        impairedExecutor.setBalance(HEALTHY_LIVE);
        healthyExecutor.setBalanceReverts(true);

        vm.expectRevert(abi.encodeWithSelector(MockExecutor.NavSettledStale.selector, uint256(1)));
        vault.executeClaimBatch(CrosschainClaimFuseEnterData({executor: address(impairedExecutor), amount: CLAIM}));

        assertEq(vault.cachedMarketBalance(), CACHED_MARKET_VALUE, "no stale aggregate was persisted");
    }

    /// @dev An ordinary NAV refresh with no recovery armed was already fail-closed and must stay so —
    ///      this pins that the new `executorCount` branch did not become the only thing standing between
    ///      a blocked chain and a substituted value.
    function test_multiExecutorMarketWithoutRecoveryStillFailsClosed() public {
        vm.expectRevert(abi.encodeWithSelector(MockExecutor.NavSettledStale.selector, uint256(1)));
        vault.refreshBalancesOnly();
    }

    /// @dev The guard must not break the normal path: with every executor live, a multi-executor market
    ///      values and persists the SUM of the live values, not a cache and not just the first one.
    function test_multiExecutorMarketWithAllExecutorsLiveSumsThemAll() public {
        impairedExecutor.setBalanceReverts(false);
        impairedExecutor.setBalance(400e6);

        vault.refreshBalancesOnly();

        assertEq(vault.cachedMarketBalance(), HEALTHY_LIVE + 400e6, "both executors summed into market NAV");
    }
}

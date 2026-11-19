// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";

import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {
    CrosschainClaimFuse,
    CrosschainClaimFuseEnterData
} from "../../contracts/fuses/crosschain/CrosschainClaimFuse.sol";
import {CrosschainBalanceFuse} from "../../contracts/fuses/crosschain/CrosschainBalanceFuse.sol";
import {CrosschainSubstrateLib} from "../../contracts/fuses/crosschain/lib/CrosschainSubstrateLib.sol";
import {CrosschainRecoveryLib} from "../../contracts/fuses/crosschain/lib/CrosschainRecoveryLib.sol";

import {PlasmaVaultExecuteHarness} from "./CrosschainRecoveryBatchScopingTest.t.sol";
import {CrosschainRecoveryContextTestLib} from "./mocks/CrosschainRecoveryContextTestLib.sol";
import {MockExecutor} from "./mocks/MockExecutor.sol";
import {MockPriceOracleMiddleware} from "./mocks/MockPriceOracleMiddleware.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

/// @notice Exposes the internal recovery-marker API of `CrosschainRecoveryLib` so that several marks in one
///         transaction can be asserted directly, including on two markets at once.
contract RecoveryMultiScopeHarness {
    function mark(uint256 marketId_, address executor_) external {
        CrosschainRecoveryLib.markRecovery(marketId_, executor_);
    }

    function markNewExposure() external {
        CrosschainRecoveryLib.markNewExposure();
    }

    function isRecovery(uint256 marketId_, address executor_) external view returns (bool) {
        return CrosschainRecoveryLib.isRecovery(marketId_, executor_);
    }

    function isRecoveryArmed() external view returns (bool) {
        return CrosschainRecoveryLib.isRecoveryArmed();
    }

    /// @dev Models a top-level transaction boundary the way every crosschain test harness does.
    function clearContext(uint256 marketId_) external {
        CrosschainRecoveryContextTestLib.clearContext(marketId_);
    }
}

/// @title CrosschainMultiExecutorRecoveryBothMarkedTest
/// @notice IL-9655 (L24): several executors of one CROSSCHAIN market can be recovery-marked in ONE transaction.
///
/// Until IL-9655 `CrosschainRecoveryLib` kept one marked `(market, executor)` scope per transaction and a second
/// `markRecovery` overwrote the first. When every executor of a market was stale at once (for example after an
/// outage of attesters they share) no batch could repair them: a batch with a recovery action on each executor
/// still reverted on the executor marked first, and a batch on one executor reverted on the stale sibling. Each
/// recovery action now adds its own scope, so `CrosschainBalanceFuse` serves `getBalanceUnchecked()` for every
/// marked stale executor.
///
/// What did NOT change and is pinned here as well: an unmarked fail-closed executor still reverts, a marked
/// `ChainBlocked` executor still reverts (IL-8611), a healthy marked executor keeps its live value, the marker does
/// not leak to another market, and a recovery batch still cannot open new exposure.
contract CrosschainMultiExecutorRecoveryBothMarkedTest is Test {
    uint256 internal constant MARKET = IporFusionMarkets.CROSSCHAIN;
    uint256 internal constant OTHER_MARKET = IporFusionMarkets.CROSSCHAIN + 1;

    /// @dev Persisted cache covering both executors, as the last successful NAV update left it.
    uint256 internal constant CACHED_MARKET_VALUE = 2_000e6;
    /// @dev Idle assets each executor holds and a claim can pull back to the vault.
    uint256 internal constant EXECUTOR_IDLE = 500e6;
    uint256 internal constant CLAIM_A = 100e6;
    uint256 internal constant CLAIM_B = 50e6;
    /// @dev Booked balances after the claims (`getBalanceUnchecked()`); `getBalance()` stays fail-closed.
    uint256 internal constant BOOKED_A = 1_100e6;
    uint256 internal constant BOOKED_B = 750e6;

    MockERC20 internal usdc;
    PlasmaVaultExecuteHarness internal vault;
    MockPriceOracleMiddleware internal oracle;

    CrosschainClaimFuse internal claimFuse;
    CrosschainBalanceFuse internal balanceFuse;

    /// @dev Stands in for the Stargate executor of the market; first in substrate order.
    MockExecutor internal executorA;
    /// @dev Stands in for the CCIP executor of the market; second in substrate order.
    MockExecutor internal executorB;

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vault = new PlasmaVaultExecuteHarness(address(usdc), 6, MARKET);

        claimFuse = new CrosschainClaimFuse(MARKET);
        balanceFuse = new CrosschainBalanceFuse(MARKET);
        vault.setFuses(address(claimFuse), address(balanceFuse));

        executorA = new MockExecutor(address(vault), address(usdc));
        executorB = new MockExecutor(address(vault), address(usdc));

        bytes32[] memory subs = new bytes32[](2);
        subs[0] = CrosschainSubstrateLib.executorSubstrate(address(executorA));
        subs[1] = CrosschainSubstrateLib.executorSubstrate(address(executorB));
        vault.grantSubstrates(subs);

        oracle = new MockPriceOracleMiddleware();
        oracle.setPrice(address(usdc), 1e8, 8);
        vault.setPriceOracleMiddleware(address(oracle));

        usdc.mint(address(executorA), EXECUTOR_IDLE);
        usdc.mint(address(executorB), EXECUTOR_IDLE);
        vault.seedMarketBalance(CACHED_MARKET_VALUE);

        // Both executors are stale: the scenario a single marker could not repair.
        executorA.setBalanceReverts(true);
        executorB.setBalanceReverts(true);
        executorA.setBalance(BOOKED_A);
        executorB.setBalance(BOOKED_B);
    }

    // ---------------------------------------------------------------------
    // Both executors stale, both marked (IL-9655 regression)
    // ---------------------------------------------------------------------

    /// @dev The finding's scenario. One batch carries a recovery action (claim) on each stale executor. Each marked
    ///      executor is valued by its booked balance and the market NAV persisted by the batch is their sum. Before
    ///      IL-9655 the claim on B overwrote A's marker and the batch reverted `NavSettledStale` on A.
    function test_bothStaleExecutorsMarkedInOneBatchAreValuedByTheirBookedBalances() public {
        vm.expectEmit(address(vault));
        emit CrosschainBalanceFuse.CrosschainUncheckedBalanceServed(
            MARKET,
            address(executorA),
            MockExecutor.NavSettledStale.selector
        );
        vm.expectEmit(address(vault));
        emit CrosschainBalanceFuse.CrosschainUncheckedBalanceServed(
            MARKET,
            address(executorB),
            MockExecutor.NavSettledStale.selector
        );

        vault.executeDoubleClaimBatch(_claim(executorA, CLAIM_A), _claim(executorB, CLAIM_B));

        assertEq(vault.cachedMarketBalance(), BOOKED_A + BOOKED_B, "market NAV = sum of both booked balances");
        assertEq(usdc.balanceOf(address(vault)), CLAIM_A + CLAIM_B, "both claims reached the vault");
        assertEq(vault.totalAssets(), CLAIM_A + CLAIM_B + BOOKED_A + BOOKED_B, "idle + persisted market NAV");
    }

    /// @dev The order of the recovery actions does not matter: the executor marked first stays marked. Before
    ///      IL-9655 the last mark (A) won and the batch reverted on B, the executor marked first.
    function test_markingOrderDoesNotMatter() public {
        vault.executeDoubleClaimBatch(_claim(executorB, CLAIM_B), _claim(executorA, CLAIM_A));

        assertEq(vault.cachedMarketBalance(), BOOKED_A + BOOKED_B, "market NAV = sum of both booked balances");
    }

    /// @dev Marking a healthy executor does not change how it is valued: its live `getBalance()` is used, and only
    ///      the stale marked executor is served by its booked balance (exactly one `CrosschainUncheckedBalanceServed`).
    ///      Before IL-9655 the claim on B overwrote A's marker and the batch reverted on the stale A.
    function test_markedHealthyExecutorKeepsItsLiveValue() public {
        uint256 liveB = 640e6;
        executorB.setBalanceReverts(false);
        executorB.setBalance(liveB);

        vm.recordLogs();
        vault.executeDoubleClaimBatch(_claim(executorA, CLAIM_A), _claim(executorB, CLAIM_B));

        assertEq(vault.cachedMarketBalance(), BOOKED_A + liveB, "A booked + B live");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 served;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(vault) &&
                logs[i].topics[0] == CrosschainBalanceFuse.CrosschainUncheckedBalanceServed.selector
            ) {
                (, address servedExecutor, ) = abi.decode(logs[i].data, (uint256, address, bytes4));
                assertEq(servedExecutor, address(executorA), "only the stale executor is served unchecked");
                ++served;
            }
        }
        assertEq(served, 1, "exactly one unchecked substitution");
    }

    // ---------------------------------------------------------------------
    // Fail-closed paths that stay closed
    // ---------------------------------------------------------------------

    /// @dev A recovery action on A alone does not entitle the stale, unmarked B to a substitution: the batch reverts
    ///      with B's fail-closed error and nothing is persisted (unchanged by IL-9655).
    function test_markedAndUnmarkedStaleExecutorStillReverts() public {
        vm.expectRevert(abi.encodeWithSelector(MockExecutor.NavSettledStale.selector, uint256(1)));
        vault.executeClaimBatch(_claim(executorA, CLAIM_A));

        assertEq(vault.cachedMarketBalance(), CACHED_MARKET_VALUE, "nothing persisted");
    }

    /// @dev Two marked executors do not open the gate for a third, unmarked stale one. C's revert carries chain id 3,
    ///      so the assertion proves the batch got past both marked executors and reverted on C itself.
    function test_twoMarkedExecutorsDoNotLaunderAThirdUnmarkedStaleExecutor() public {
        MockExecutor executorC = new MockExecutor(address(vault), address(usdc));
        bytes memory staleOnChain3 = abi.encodeWithSelector(MockExecutor.NavSettledStale.selector, uint256(3));
        executorC.setFailMode(MockExecutor.FailMode.RAW, staleOnChain3);
        executorC.setBalance(300e6);

        bytes32[] memory subs = new bytes32[](3);
        subs[0] = CrosschainSubstrateLib.executorSubstrate(address(executorA));
        subs[1] = CrosschainSubstrateLib.executorSubstrate(address(executorB));
        subs[2] = CrosschainSubstrateLib.executorSubstrate(address(executorC));
        vault.grantSubstrates(subs);

        vm.expectRevert(staleOnChain3);
        vault.executeDoubleClaimBatch(_claim(executorA, CLAIM_A), _claim(executorB, CLAIM_B));

        assertEq(vault.cachedMarketBalance(), CACHED_MARKET_VALUE, "nothing persisted");
    }

    /// @dev Both executors marked, B's `getBalance()` reverts `ChainBlocked`: B's books are known-inconsistent, so the
    ///      batch reverts with the original returndata even though A could be substituted (IL-8611, unchanged).
    function test_markedChainBlockedExecutorStillRevertsWhenBothAreMarked() public {
        executorB.setBalanceBlocked(true);

        vm.expectRevert(abi.encodeWithSelector(MockExecutor.ChainBlocked.selector, uint256(1)));
        vault.executeDoubleClaimBatch(_claim(executorA, CLAIM_A), _claim(executorB, CLAIM_B));

        assertEq(vault.cachedMarketBalance(), CACHED_MARKET_VALUE, "nothing persisted");
    }

    /// @dev Both executors marked and stale, but B refuses the unchecked read while one of its chains is blocked:
    ///      that `ChainBlocked` bubbles out of the balance fuse (unchanged).
    function test_markedStaleExecutorWithABlockedChainStillRevertsWhenBothAreMarked() public {
        executorB.setUncheckedBlocked(true);

        vm.expectRevert(abi.encodeWithSelector(MockExecutor.ChainBlocked.selector, uint256(1)));
        vault.executeDoubleClaimBatch(_claim(executorA, CLAIM_A), _claim(executorB, CLAIM_B));

        assertEq(vault.cachedMarketBalance(), CACHED_MARKET_VALUE, "nothing persisted");
    }

    /// @dev An ordinary refresh with no recovery action keeps failing closed while both executors are stale.
    function test_bothStaleWithoutRecoveryStillFailsClosed() public {
        vm.expectRevert(abi.encodeWithSelector(MockExecutor.NavSettledStale.selector, uint256(1)));
        vault.refreshBalancesOnly();
    }

    // ---------------------------------------------------------------------
    // Marker set mechanics (library level, two markets on one harness)
    // ---------------------------------------------------------------------

    /// @dev Every marked scope stays marked after later marks, and none of them leaks to another market or to an
    ///      executor no recovery action drove. Before IL-9655 only the last mark answered true.
    function test_everyMarkedScopeStaysMarkedAndNothingLeaksToAnotherMarket() public {
        RecoveryMultiScopeHarness harness = new RecoveryMultiScopeHarness();
        address a = address(0xA11);
        address b = address(0xB22);
        address c = address(0xC33);

        harness.mark(MARKET, a);
        harness.mark(MARKET, b);
        harness.mark(OTHER_MARKET, c);

        assertTrue(harness.isRecovery(MARKET, a), "A marked on MARKET");
        assertTrue(harness.isRecovery(MARKET, b), "B marked on MARKET");
        assertTrue(harness.isRecovery(OTHER_MARKET, c), "C marked on OTHER_MARKET");
        assertFalse(harness.isRecovery(OTHER_MARKET, a), "A's mark does not leak to OTHER_MARKET");
        assertFalse(harness.isRecovery(OTHER_MARKET, b), "B's mark does not leak to OTHER_MARKET");
        assertFalse(harness.isRecovery(MARKET, c), "C's mark does not leak to MARKET");
        assertFalse(harness.isRecovery(MARKET, address(0xD44)), "an executor no action drove is not marked");
        assertTrue(harness.isRecoveryArmed(), "batch-level flag set");
    }

    /// @dev Marking the same scope again is a no-op: both scopes stay marked, whatever the order of repeats.
    function test_markingTheSameScopeAgainKeepsEveryScope() public {
        RecoveryMultiScopeHarness harness = new RecoveryMultiScopeHarness();
        address a = address(0xA11);
        address b = address(0xB22);

        harness.mark(MARKET, a);
        harness.mark(MARKET, a);
        harness.mark(MARKET, b);
        harness.mark(MARKET, a);
        harness.mark(MARKET, b);

        assertTrue(harness.isRecovery(MARKET, a), "A marked");
        assertTrue(harness.isRecovery(MARKET, b), "B marked");
        assertFalse(harness.isRecovery(MARKET, address(0xC33)), "C not marked");
    }

    /// @dev Several marks keep the recovery / new-exposure exclusion a batch-level property, both ways.
    function test_newExposureStaysForbiddenAfterSeveralRecoveryMarks() public {
        RecoveryMultiScopeHarness harness = new RecoveryMultiScopeHarness();
        harness.mark(MARKET, address(0xA11));
        harness.mark(MARKET, address(0xB22));

        vm.expectRevert(CrosschainRecoveryLib.RecoveryExposureBatchForbidden.selector);
        harness.markNewExposure();

        RecoveryMultiScopeHarness exposureFirst = new RecoveryMultiScopeHarness();
        exposureFirst.markNewExposure();

        vm.expectRevert(CrosschainRecoveryLib.RecoveryExposureBatchForbidden.selector);
        exposureFirst.mark(MARKET, address(0xA11));
    }

    /// @dev The test-only transaction boundary (`CrosschainRecoveryContextTestLib.clearContext`) drops every marked
    ///      scope at once, and a scope marked before it does not resurface when another scope is marked after it, so
    ///      the crosschain harnesses that model several transactions in one test stay valid.
    function test_testTransactionBoundaryDropsEveryMarkedScope() public {
        RecoveryMultiScopeHarness harness = new RecoveryMultiScopeHarness();
        address a = address(0xA11);
        address b = address(0xB22);

        harness.mark(MARKET, a);
        harness.mark(MARKET, b);
        harness.clearContext(MARKET);

        assertFalse(harness.isRecovery(MARKET, a), "A dropped");
        assertFalse(harness.isRecovery(MARKET, b), "B dropped");
        assertFalse(harness.isRecoveryArmed(), "nothing armed");

        harness.mark(MARKET, b);

        assertFalse(harness.isRecovery(MARKET, a), "A does not resurface");
        assertTrue(harness.isRecovery(MARKET, b), "B marked again");
    }

    function _claim(
        MockExecutor executor_,
        uint256 amount_
    ) private pure returns (CrosschainClaimFuseEnterData memory) {
        return CrosschainClaimFuseEnterData({executor: address(executor_), amount: amount_});
    }
}

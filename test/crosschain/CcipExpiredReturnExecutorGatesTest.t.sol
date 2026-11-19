// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {CcipExpiredReturnFixture} from "test/crosschain/CcipExpiredReturnFixture.sol";
import {CcipCrosschainExecutor} from "contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipExecutorTransferLib} from "contracts/crosschain/ccip/lib/CcipExecutorTransferLib.sol";
import {CcipChainRescue} from "contracts/crosschain/lib/CrosschainConstants.sol";

/// @title CcipExpiredReturnExecutorGatesBase
/// @notice IL-9621 (K11): the executor side of the zero return that `flushExpiredReturn()` sends for a recall whose
///         tokens could not leave the dispatcher. A real executor and dispatcher on the in-memory router; the
///         zero return is delivered through the normal response path (`deliverHeld` where the order matters).
///         The setup funds the dispatcher with 100 units and attests them, so `settled` is 100 and NAV is live.
/// @dev The promise the tests pin is the narrow one: the zero return removes the recall's dependency on a token
///      transfer. It does not open NAV by itself; NAV opens only when every other gate allows it (version order,
///      observation age, chain block, other transfers' staleness clocks).
abstract contract CcipExpiredReturnExecutorGatesBase is CcipExpiredReturnFixture {
    event ReturnFinalized(uint256 chainId, bytes32 operationId, uint256 sentSD, uint256 received, uint256 debitedSD);
    event LateReturnFinalized(
        uint256 chainId,
        bytes32 operationId,
        uint256 sentSD,
        uint256 received,
        uint256 debitedSD
    );
    event ReturnBelowMinimumCredited(uint256 chainId, bytes32 operationId, uint256 received, uint256 minimum);

    uint256 internal constant FUNDED = 100e18;
    uint256 internal constant RECALL = 60e18;
    /// @dev `CrosschainConstants.MAX_CANCELLED_RECALLS_PER_CHAIN`.
    uint256 internal constant CAP = 4;

    function setUp() public {
        vm.warp(365 days);
        _expiredFixtureSetUp();
        _bridge(FUNDED);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(FUNDED);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), FUNDED, "setup: settled");
        assertEq(dispatcher.trackedIdle(), FUNDED, "setup: dispatcher idle");
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Token-bearing sends stay blocked, a recall of `amountLD_` is opened and its `RETURN_TRANSFER` is stuck in
    ///      the dispatcher queue.
    /// @return deadline The recall deadline.
    /// @return operationId The recall's operation id.
    function _stuckRecall(uint256 amountLD_) internal returns (uint256 deadline, bytes32 operationId) {
        _blockTokenSends();
        deadline = _recall(amountLD_);
        operationId = executor.activeReturn(REMOTE_CHAIN);
        assertTrue(operationId != bytes32(0), "recall open");
        assertTrue(dispatcher.responseQueueHead() != 0, "return stuck in the dispatcher queue");
    }

    /// @dev From now on every message of the router is held until `deliverHeld`.
    function _hold() internal {
        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
    }

    function _lastHeld() internal view returns (uint256) {
        return router.heldCount() - 1;
    }

    /// @dev Moves past `deadline_` and releases the head with `flushExpiredReturn()`.
    function _release(uint256 deadline_) internal {
        vm.warp(deadline_ + 1);
        assertTrue(dispatcher.flushExpiredReturn(), "released without tokens");
    }

    function _expectNav(bytes memory error_) internal {
        vm.expectRevert(error_);
        executor.getBalance();
    }

    function _expectNavOpen() internal view {
        _expectNavAt(FUNDED);
    }

    function _expectNavAt(uint256 expected_) internal view {
        assertEq(executor.getBalance(), expected_, "NAV open at the expected value");
    }

    function _transferStale(uint256 createdAt_) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(CcipExecutorTransferLib.TransferStale.selector, REMOTE_CHAIN, createdAt_);
    }

    function _gap(uint64 expected_, uint64 got_) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(CcipCrosschainExecutor.StateVersionGap.selector, REMOTE_CHAIN, expected_, got_);
    }

    function _forceSetSettled(uint256 settledLD_) internal {
        vm.warp(block.timestamp + 1); // observation strictly after the last value-moving receipt
        uint256 arg = (uint256(executor.lastRemoteStateVersion(REMOTE_CHAIN)) << 192) |
            (block.timestamp << 128) |
            settledLD_;
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
    }
}

/// @notice Zero return of an active recall, cancelled recalls, out-of-order delivery and the gates that stay closed.
contract CcipExpiredReturnExecutorGatesTest is CcipExpiredReturnExecutorGatesBase {
    // ------------------------------------------------------------------ active recall

    /// @notice The reported scenario: the token sends of the dispatcher stay blocked for the whole test, yet after the
    ///         deadline the valuation opens, with the tokens still on the dispatcher.
    function testShouldOpenNavAfterTheDeadlineWhileTokenSendsStayBlocked() public {
        (uint256 deadline, bytes32 operationId) = _stuckRecall(RECALL);
        uint256 recallAt = deadline - _transferStalenessMax();
        uint64 frontier = executor.lastRemoteStateVersion(REMOTE_CHAIN);

        vm.warp(deadline + 1);
        _expectNav(_transferStale(recallAt));

        vm.expectEmit(address(executor));
        emit ReturnFinalized(REMOTE_CHAIN, operationId, 0, 0, 0);
        assertTrue(dispatcher.flushExpiredReturn(), "released without tokens");

        _expectNavOpen();
        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0), "recall closed");
        assertEq(
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            frontier + 1,
            "its version consumed, frontier contiguous"
        );
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), FUNDED, "settled unchanged");
        assertEq(executor.idleLedger(), 0, "nothing credited");
        assertEq(token.balanceOf(address(executor)), 0, "no tokens arrived");
        assertEq(token.balanceOf(address(dispatcher)), FUNDED, "the tokens never left the dispatcher");
        assertEq(dispatcher.trackedIdle(), FUNDED, "and are idle again");
    }

    /// @notice A held zero return: before it lands the recall stays open and NAV closed; it closes the recall with
    ///         `sentSD == 0` and `received == 0` and the manager can ask again once token sends work.
    function testShouldFinalizeWithZeroAmountsAndAllowANewRecall() public {
        (uint256 deadline, bytes32 operationId) = _stuckRecall(RECALL);
        _hold();
        _release(deadline);
        assertEq(executor.activeReturn(REMOTE_CHAIN), operationId, "still open until delivered");

        vm.expectEmit(address(executor));
        emit ReturnFinalized(REMOTE_CHAIN, operationId, 0, 0, 0);
        router.deliverHeld(_lastHeld());

        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0), "closed by the delivery");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), FUNDED, "settled unchanged");
        assertEq(executor.idleLedger(), 0);

        router.setAutoDeliver(true);
        _unblockSends();
        _recall(RECALL);
        assertEq(executor.idleLedger(), RECALL, "the second recall brings the tokens");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), FUNDED - RECALL, "and debits settled");
        assertEq(executor.getBalance(), FUNDED, "NAV unchanged by the recall");
    }

    /// @notice With a positive `minReturn` the executor still credits what arrived (nothing) and says so.
    function testShouldEmitReturnBelowMinimumCreditedForAZeroReturnWithAFloor() public {
        _blockTokenSends();
        uint256 deadline = block.timestamp + _transferStalenessMax();
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, RECALL, RECALL, 0, address(0), ROUTE_GAS_LIMIT);
        bytes32 operationId = executor.activeReturn(REMOTE_CHAIN);

        vm.warp(deadline + 1);
        vm.expectEmit(address(executor));
        emit ReturnBelowMinimumCredited(REMOTE_CHAIN, operationId, 0, RECALL);
        vm.expectEmit(address(executor));
        emit ReturnFinalized(REMOTE_CHAIN, operationId, 0, 0, 0);
        assertTrue(dispatcher.flushExpiredReturn());

        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0), "the floor does not keep the recall open");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), FUNDED);
        _expectNavOpen();
    }

    /// @notice `sentSD == 0` means the recall was closed without tokens (nothing was lost); `sentSD > 0` with
    ///         `received == 0` is a transport loss and `settled` is debited. The two are told apart by the event.
    function testShouldTellAClosedWithoutTokensRecallFromATransportLoss() public {
        // Closed without tokens: nothing debited.
        (uint256 deadline, bytes32 closedId) = _stuckRecall(RECALL);
        vm.expectEmit(address(executor));
        emit ReturnFinalized(REMOTE_CHAIN, closedId, 0, 0, 0);
        _release(deadline);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), FUNDED, "closed without tokens: settled kept");

        // Transport loss: the tokens leave the dispatcher, the pool withholds all of them.
        _unblockSends();
        router.setPoolHaircutBps(10_000);
        vm.recordLogs();
        _recall(RECALL);
        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0), "the lossy return was delivered at once");
        (uint256 sentSD, uint256 received) = _finalizedAmounts(vm.getRecordedLogs());
        assertEq(sentSD, RECALL, "the dispatcher declared the sent amount");
        assertEq(received, 0, "nothing arrived");
        assertEq(executor.idleLedger(), 0, "nothing credited");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), FUNDED - RECALL, "transport loss: settled debited");
    }

    function _finalizedAmounts(Vm.Log[] memory logs_) private view returns (uint256 sentSD, uint256 received) {
        bytes32 topic = ReturnFinalized.selector;
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(executor) && logs_[i].topics[0] == topic) {
                (, , sentSD, received, ) = abi.decode(logs_[i].data, (uint256, bytes32, uint256, uint256, uint256));
                return (sentSD, received);
            }
        }
        revert("ReturnFinalized not emitted");
    }

    // ------------------------------------------------------------------ cancelled recalls

    /// @notice Two cancelled recalls. The zero return of the older one lands: the cancelled-recall clock moves to
    ///         the newer one (it does not clear, and the resolved recall's window no longer closes NAV).
    function testShouldMoveTheCancelledClockToTheOldestUnresolvedRecall() public {
        (uint256 deadline1, ) = _stuckRecall(1e18);
        uint256 firstAt = deadline1 - _transferStalenessMax();
        executor.cancelPendingReturn(REMOTE_CHAIN);
        vm.warp(block.timestamp + 6 hours);
        uint256 deadline2 = _recall(1e18);
        uint256 secondAt = deadline2 - _transferStalenessMax();
        executor.cancelPendingReturn(REMOTE_CHAIN);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 2);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), firstAt, "the older recall anchors the clock");

        _hold();
        _release(deadline1);
        router.deliverHeld(_lastHeld());
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 1, "the older recall is resolved");
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), secondAt, "clock moved to the oldest unresolved");
        _expectNavOpen(); // past the first recall's window, inside the second one's

        vm.warp(deadline2 + 1);
        _expectNav(_transferStale(secondAt));
        assertTrue(dispatcher.flushExpiredReturn(), "the newer recall is released too");
        router.deliverHeld(_lastHeld());
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), 0, "clock cleared by the last zero return");
        _expectNavOpen();
    }

    /// @notice A zero return that belongs to a generation before a reset has no effect on the new generation's
    ///         cancelled-recall clock; the new recall's own zero return resolves it.
    function testShouldIgnoreAnOlderGenerationZeroReturnAfterAReset() public {
        (, bytes32 idA) = _stuckRecall(1e18);
        executor.cancelPendingReturn(REMOTE_CHAIN);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 1);
        assertEq(executor.cancelledRecallGeneration(REMOTE_CHAIN), 0);

        _forceSetSettled(FUNDED); // reset: new generation, A's recall is no longer tracked
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0, "reset empties the queue");
        assertEq(executor.cancelledRecallGeneration(REMOTE_CHAIN), 1);

        uint256 deadlineB = _recall(1e18);
        uint256 recallBAt = deadlineB - _transferStalenessMax();
        bytes32 idB = executor.activeReturn(REMOTE_CHAIN);
        executor.cancelPendingReturn(REMOTE_CHAIN);
        assertEq(executor.cancelledRecallGenerationOf(idA), 0);
        assertEq(executor.cancelledRecallGenerationOf(idB), 1);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), recallBAt);

        // A's deadline passed long ago, B's has not: A is the head and is released first.
        _hold();
        assertTrue(dispatcher.flushExpiredReturn(), "A released");
        vm.expectEmit(address(executor));
        emit LateReturnFinalized(REMOTE_CHAIN, idA, 0, 0, 0);
        router.deliverHeld(_lastHeld());
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 1, "the older generation's zero return is ignored");
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), recallBAt, "B's clock untouched");

        vm.warp(deadlineB + 1);
        _expectNav(_transferStale(recallBAt));
        assertTrue(dispatcher.flushExpiredReturn(), "B released");
        router.deliverHeld(_lastHeld());
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0, "B's own zero return resolves it");
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), 0);
        _expectNavOpen();
    }

    /// @notice Four cancelled recalls fill the manager cap; the zero return of one of them frees a slot.
    function testShouldFreeACancelledRecallSlotWhenItsZeroReturnLands() public {
        _blockTokenSends();
        uint256 deadline;
        for (uint256 i; i < CAP; ++i) {
            deadline = _recall(1e18);
            executor.cancelPendingReturn(REMOTE_CHAIN);
        }
        _recall(1e18); // the fifth recall stays active
        vm.expectRevert(
            abi.encodeWithSelector(CcipExecutorTransferLib.CancelledRecallCapReached.selector, REMOTE_CHAIN, CAP)
        );
        executor.cancelPendingReturn(REMOTE_CHAIN);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), CAP, "cap reached");

        _hold();
        _release(deadline);
        router.deliverHeld(_lastHeld());
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), CAP - 1, "one slot is free");

        executor.cancelPendingReturn(REMOTE_CHAIN);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), CAP, "the fifth recall could be cancelled");
        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0));
    }

    // ------------------------------------------------------------------ delayed and out-of-order delivery

    /// @notice An earlier version (a settle sent first) is still in transit when the zero return arrives: the zero
    ///         return reverts `StateVersionGap` with all effects rolled back and succeeds once the settle landed.
    function testShouldRevertStateVersionGapForAZeroReturnWhenAnEarlierVersionIsMissing() public {
        _hold();
        _bridge(10e18); // held (token message)
        router.deliverHeld(_lastHeld()); // dispatcher queues TRANSFER_SETTLED v+1, held
        uint256 settleIndex = _lastHeld();
        uint64 frontier = executor.lastRemoteStateVersion(REMOTE_CHAIN);

        _blockTokenSends();
        uint256 deadline = block.timestamp + _transferStalenessMax();
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, RECALL, 0, 0, address(0), ROUTE_GAS_LIMIT);
        bytes32 operationId = executor.activeReturn(REMOTE_CHAIN);
        router.deliverHeld(_lastHeld()); // the request reaches the dispatcher, its return v+2 is stuck
        _release(deadline);
        uint256 zeroIndex = _lastHeld();

        vm.expectRevert(_gap(frontier + 1, frontier + 2));
        router.deliverHeld(zeroIndex);
        assertEq(executor.activeReturn(REMOTE_CHAIN), operationId, "the recall stays open");
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), frontier, "frontier untouched");

        router.deliverHeld(settleIndex);
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), frontier + 1, "the settle landed");
        router.deliverHeld(zeroIndex); // re-execution
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), frontier + 2, "the zero return landed");
        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0));
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), FUNDED + 10e18, "settle credited, nothing debited");
    }

    /// @notice A settle queued behind the stuck return is sent after it, but delivered before it: the settle reverts
    ///         `StateVersionGap`, the zero return lands, then the settle is re-executed.
    function testShouldRevertStateVersionGapForAVersionedResponseDeliveredBeforeTheZeroReturn() public {
        _hold();
        _blockTokenSends();
        uint256 deadline = block.timestamp + _transferStalenessMax();
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, RECALL, 0, 0, address(0), ROUTE_GAS_LIMIT);
        router.deliverHeld(_lastHeld()); // return v+1 is stuck at the dispatcher head
        _bridge(10e18);
        router.deliverHeld(_lastHeld()); // the settle v+2 queues behind it
        uint64 frontier = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        uint256 heldBefore = router.heldCount();

        _release(deadline);
        uint256 zeroIndex = _lastHeld();
        assertEq(dispatcher.flushResponse(1), 1, "the settle behind the released return is sent");
        assertEq(router.heldCount(), heldBefore + 2, "zero return and settle held");
        uint256 settleIndex = _lastHeld();

        vm.expectRevert(_gap(frontier + 1, frontier + 2));
        router.deliverHeld(settleIndex);

        router.deliverHeld(zeroIndex);
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), frontier + 1, "zero return applied");
        router.deliverHeld(settleIndex); // re-execution
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), frontier + 2, "settle applied after it");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), FUNDED + 10e18);
        _expectNavAt(FUNDED + 10e18);
    }

    // ------------------------------------------------------------------ gates that stay closed

    /// @notice The delivery of the zero return does not make an approved chain block go away: NAV stays
    ///         `ChainBlocked` until the timelocked rescue lifts it.
    function testShouldKeepNavClosedOnAChainBlockAfterTheZeroReturnIsDelivered() public {
        (uint256 deadline, ) = _stuckRecall(RECALL);
        uint256 proposalId = _propose(FUNDED - 10e18);
        vm.prank(APPROVER);
        executor.rejectBalanceAndBlock(proposalId);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN));

        vm.warp(deadline + 1);
        _expectNav(abi.encodeWithSelector(CcipExecutorTransferLib.ChainBlocked.selector, REMOTE_CHAIN));
        assertTrue(dispatcher.flushExpiredReturn());
        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0), "the recall is closed");

        bytes memory blocked = abi.encodeWithSelector(CcipExecutorTransferLib.ChainBlocked.selector, REMOTE_CHAIN);
        _expectNav(blocked);
        _attest(FUNDED);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "an approval does not lift the block");
        _expectNav(blocked);

        _forceSetSettled(FUNDED);
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "the timelocked rescue lifts it");
        _expectNavOpen();
    }

    /// @notice Another transfer's staleness clock keeps NAV closed after the zero return is delivered; it opens only
    ///         once that transfer's settle lands.
    function testShouldKeepNavClosedOnAnotherStaleTransferAfterTheZeroReturnIsDelivered() public {
        _hold();
        _bridge(10e18); // held, never delivered until later: the other transfer
        uint256 bridgeIndex = _lastHeld();
        uint256 transferAt = block.timestamp;
        vm.warp(block.timestamp + 1 hours);

        _blockTokenSends();
        uint256 deadline = block.timestamp + _transferStalenessMax();
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, RECALL, 0, 0, address(0), ROUTE_GAS_LIMIT);
        router.deliverHeld(_lastHeld()); // the return v+1 is stuck at the dispatcher head
        _release(deadline);
        router.deliverHeld(_lastHeld()); // the zero return lands
        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0), "the recall is closed");

        _expectNav(_transferStale(transferAt));

        router.deliverHeld(bridgeIndex); // the tokens of the other transfer reach the dispatcher
        router.deliverHeld(_lastHeld()); // and its settle is delivered
        _expectNavAt(FUNDED + 10e18);
    }
}

/// @notice The observation gate with a short `balanceStalenessMax` (2 days, below the recall deadline plus the age
///         of the attestation).
contract CcipExpiredReturnExecutorGatesShortObservationTest is CcipExpiredReturnExecutorGatesBase {
    function _expiredBalanceStalenessMax() internal pure override returns (uint256) {
        return 2 days;
    }

    /// @notice The attestation is older than `balanceStalenessMax` when the zero return lands: NAV stays closed on
    ///         `ObservationStale` and opens with a new observation taken after the return was accepted.
    function testShouldKeepNavClosedOnObservationStaleUntilANewObservation() public {
        vm.warp(block.timestamp + 1.5 days);
        (uint256 deadline, ) = _stuckRecall(RECALL);

        vm.warp(deadline + 1);
        _expectNav(_transferStale(deadline - _transferStalenessMax()));

        assertTrue(dispatcher.flushExpiredReturn(), "released without tokens");
        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0), "the recall is closed");
        _expectNav(abi.encodeWithSelector(CcipExecutorTransferLib.ObservationStale.selector, REMOTE_CHAIN));

        _attest(FUNDED); // a new observation, strictly after the zero return
        _expectNavOpen();
    }

    /// @notice Control: with an observation that is still fresh the zero return alone opens NAV.
    function testShouldOpenNavWhenTheObservationIsStillFresh() public {
        (uint256 deadline, ) = _stuckRecall(RECALL);
        vm.warp(deadline + 1);
        assertTrue(dispatcher.flushExpiredReturn());
        _expectNavOpen();
    }
}

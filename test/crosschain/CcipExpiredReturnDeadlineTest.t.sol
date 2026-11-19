// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CcipExpiredReturnFixture} from "test/crosschain/CcipExpiredReturnFixture.sol";
import {CcipMsgType} from "contracts/crosschain/ccip/lib/CcipMessages.sol";

/// @title CcipExpiredReturnDeadlineTest
/// @notice IL-9621: the recall deadline kept in the queue entry of a `RETURN_TRANSFER` that stays queued, its
///         lifecycle (written, read through `queuedReturnDeadline`, cleared by every removal of the entry), the
///         boundary of `flushExpiredReturn` (the deadline second itself is not expired) and its failure semantics
///         (any failure of the token-bearing attempt leads to the token-less send; a failing token-less send
///         reverts the whole call and leaves the queue, the ledgers and the deadline as they were).
contract CcipExpiredReturnDeadlineTest is CcipExpiredReturnFixture {
    event ReturnExpiredUnwound(bytes32 operationId, uint256 amount, uint64 responseId);
    event ReturnBelowMinimumCredited(uint256 chainId, bytes32 operationId, uint256 received, uint256 minimum);

    error ReturnNotExpired(uint64 responseId, uint256 deadline);
    error NoQueuedResponse();
    error CcipFeeTooHigh(uint256 fee, uint256 maxFee);
    error CcipInsufficientNativeFeeBalance(uint256 balance, uint256 required);
    error CcipUnknownChain(uint256 chainId);
    error TokenMaxCapacityExceeded(uint256 capacity, uint256 requested, address tokenAddress);
    error PoolDisabled();

    uint256 internal constant FUNDED = 100e18;
    uint256 internal constant RECALL = 60e18;
    uint256 internal constant SECOND_RECALL = 30e18;
    uint256 internal constant FEE_CEILING = 10 ether;

    /// @dev Everything `flushExpiredReturn` must leave alone when it reverts.
    struct Snapshot {
        uint256 trackedIdle;
        uint256 queuedTokenAmount;
        uint64 stateVersion;
        uint256 accountedBalance;
        uint64 head;
        uint64 tail;
        bytes32 queueHash;
    }

    function _routeMaxFee() internal pure override returns (uint256) {
        return FEE_CEILING;
    }

    function setUp() public {
        vm.warp(365 days);
        _expiredFixtureSetUp();
        _bridge(FUNDED);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(FUNDED);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
    }

    // ------------------------------------------------------------------ helpers

    /// @dev A recall whose return cannot leave (token sends blocked): the head with its deadline.
    function _stuckReturn() internal returns (uint64 head, uint256 deadline) {
        _blockTokenSends();
        deadline = _recall(RECALL);
        head = dispatcher.responseQueueHead();
        assertEq(head, dispatcher.responseQueueTail(), "the stuck return is the only entry");
    }

    /// @dev Cancels the active recall on the executor and queues a second return behind the stuck head.
    function _returnBehindHead() internal returns (uint64 second, uint256 secondDeadline) {
        executor.cancelPendingReturn(REMOTE_CHAIN);
        vm.warp(block.timestamp + 1);
        secondDeadline = _recall(SECOND_RECALL);
        second = dispatcher.responseQueueTail();
    }

    function _policy(bool enabled_) internal pure returns (uint256) {
        return uint256(ROUTE_GAS_LIMIT) | (uint256(ROUTE_GAS_LIMIT) << 96) | (enabled_ ? uint256(1) << 192 : 0);
    }

    function _setRoute(bool enabled_, uint256 maxFee_) internal {
        vm.prank(factory);
        dispatcher.syncRoutePolicy(address(0), _policy(enabled_), maxFee_);
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        s.trackedIdle = dispatcher.trackedIdle();
        s.queuedTokenAmount = dispatcher.queuedTokenAmount();
        s.stateVersion = dispatcher.stateVersion();
        s.accountedBalance = dispatcher.accountedBalance();
        s.head = dispatcher.responseQueueHead();
        s.tail = dispatcher.responseQueueTail();
        bytes32 acc;
        for (uint64 id = s.head; id != 0 && id <= s.tail; ++id) {
            (bytes memory data, address queuedToken, uint256 amountLD) = dispatcher.queuedResponse(id);
            acc = keccak256(abi.encode(acc, id, data, queuedToken, amountLD, dispatcher.queuedReturnDeadline(id)));
        }
        s.queueHash = acc;
    }

    function _assertSame(Snapshot memory a_, Snapshot memory b_) internal pure {
        assertEq(a_.trackedIdle, b_.trackedIdle, "trackedIdle kept");
        assertEq(a_.queuedTokenAmount, b_.queuedTokenAmount, "queuedTokenAmount kept");
        assertEq(a_.stateVersion, b_.stateVersion, "stateVersion kept");
        assertEq(a_.accountedBalance, b_.accountedBalance, "accountedBalance kept");
        assertEq(a_.head, b_.head, "head kept");
        assertEq(a_.tail, b_.tail, "tail kept");
        assertEq(a_.queueHash, b_.queueHash, "every queued payload and deadline byte for byte");
    }

    function _returnOperationId(uint64 id_) internal view returns (bytes32 operationId) {
        (, bytes memory payload) = _queuedPayload(id_);
        (operationId, , , ) = _decodeReturn(payload);
    }

    /// @dev Stuck return plus one behind it, past the first deadline, with the token send failing for another
    ///      reason than the rate limit (the pure fee cases set their own fees).
    function _expiredWithEntryBehind() internal returns (uint64 head, uint64 second, uint256 deadline) {
        (head, deadline) = _stuckReturn();
        (second, ) = _returnBehindHead();
        _unblockSends();
        vm.warp(deadline + 1);
    }

    // ------------------------------------------------------------------ deadline written

    function testShouldKeepTheDeadlineOfAHeadWhoseSendFailed() public {
        (uint64 head, uint256 deadline) = _stuckReturn();
        assertEq(dispatcher.queuedReturnDeadline(head), deadline, "deadline of the executor's request kept");
        assertEq(deadline, block.timestamp + _transferStalenessMax(), "stamped createdAt + staleness max");
        (CcipMsgType messageType, ) = _queuedPayload(head);
        assertEq(uint8(messageType), uint8(CcipMsgType.RETURN_TRANSFER), "a queued return");
    }

    function testShouldKeepTheDeadlineOfAReturnQueuedBehindABusyHead() public {
        (uint64 head, uint256 firstDeadline) = _stuckReturn();
        (uint64 second, uint256 secondDeadline) = _returnBehindHead();
        assertEq(second, head + 1, "queued right behind the head");
        assertEq(dispatcher.queuedReturnDeadline(head), firstDeadline, "head deadline untouched");
        assertEq(dispatcher.queuedReturnDeadline(second), secondDeadline, "deadline of the entry behind the head");
        assertGt(secondDeadline, firstDeadline, "each entry has its own request deadline");
    }

    function testShouldReportNoDeadlineForUnknownIds() public view {
        assertEq(dispatcher.queuedReturnDeadline(0), 0, "id 0");
        assertEq(dispatcher.queuedReturnDeadline(7), 0, "never queued");
    }

    function testShouldNotWriteADeadlineWhenTheReturnLeavesAtOnce() public {
        _recall(RECALL);
        assertEq(dispatcher.responseQueueHead(), 0, "sent at once");
        assertEq(dispatcher.queuedReturnDeadline(dispatcher.responseQueueTail()), 0, "no deadline for a sent return");
        assertEq(token.balanceOf(address(executor)), RECALL, "tokens left");
    }

    function testShouldNotWriteADeadlineForAnExpiredRequest() public {
        router.setAutoDeliver(false);
        uint256 deadline = _recall(RECALL);
        uint256 requestIndex = router.heldCount() - 1;
        vm.warp(deadline + 1);
        uint64 tailBefore = dispatcher.responseQueueTail();
        uint256 idleBefore = dispatcher.trackedIdle();
        router.deliverHeld(requestIndex);
        assertEq(dispatcher.trackedIdle(), idleBefore, "nothing debited");
        assertEq(dispatcher.responseQueueTail(), tailBefore + 1, "only the rejection was queued");
        assertEq(dispatcher.responseQueueHead(), 0, "the rejection left at once");
        assertEq(dispatcher.queuedReturnDeadline(tailBefore + 1), 0, "no deadline for the EXPIRED rejection");
        assertEq(dispatcher.queuedReturnDeadline(tailBefore), 0, "no deadline invented for the previous id");
    }

    function testShouldNotWriteADeadlineWhenTheReturnIsRejectedAbovePoolCapacity() public {
        router.setFailSendWith(
            address(dispatcher),
            abi.encodeWithSelector(TokenMaxCapacityExceeded.selector, 10e18, RECALL, address(token))
        );
        uint64 tailBefore = dispatcher.responseQueueTail();
        _recall(RECALL);
        uint64 dropped = tailBefore + 1;
        assertEq(dispatcher.responseQueueTail(), tailBefore + 2, "the dropped return and its rejection");
        assertEq(dispatcher.responseQueueHead(), 0, "queue empty");
        assertEq(dispatcher.queuedReturnDeadline(dropped), 0, "no deadline for the dropped return");
        assertEq(dispatcher.trackedIdle(), FUNDED, "tracked idle re-credited");
        assertEq(dispatcher.queuedTokenAmount(), 0, "nothing left in the queue bucket");
    }

    // ------------------------------------------------------------------ deadline cleared

    function testShouldClearTheDeadlineAfterANormalSend() public {
        (uint64 head, uint256 deadline) = _stuckReturn();
        assertEq(dispatcher.queuedReturnDeadline(head), deadline, "kept while stuck");
        _unblockSends();
        dispatcher.flushResponse();
        assertEq(dispatcher.responseQueueHead(), 0, "sent");
        assertEq(dispatcher.queuedReturnDeadline(head), 0, "cleared with the entry");
    }

    function testShouldClearTheDeadlineAfterARelease() public {
        (uint64 head, uint256 deadline) = _stuckReturn();
        vm.warp(deadline + 1);
        assertTrue(dispatcher.flushExpiredReturn(), "released without tokens");
        assertEq(dispatcher.queuedReturnDeadline(head), 0, "cleared with the entry");
        assertEq(dispatcher.responseQueueHead(), 0, "queue empty");
    }

    function testShouldClearTheDeadlineAfterASkipAndKeepTheOneBehind() public {
        (uint64 head, ) = _stuckReturn();
        (uint64 second, uint256 secondDeadline) = _returnBehindHead();
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = dispatcher.scheduleSkipStuckResponse(head);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        dispatcher.executeSkipStuckResponse(rescueId, head);
        assertEq(dispatcher.queuedReturnDeadline(head), 0, "cleared with the skipped entry");
        assertEq(dispatcher.responseQueueHead(), second, "the next return is the head");
        assertEq(dispatcher.queuedReturnDeadline(second), secondDeadline, "its own deadline stays");
    }

    function testShouldClearTheDeadlineOfTheReleasedHeadAndKeepTheOneBehind() public {
        (uint64 head, uint64 second, ) = _expiredWithEntryBehind();
        uint256 secondDeadline = dispatcher.queuedReturnDeadline(second);
        assertGt(secondDeadline, 0, "second deadline kept");
        _blockTokenSends();
        assertTrue(dispatcher.flushExpiredReturn(), "head released");
        assertEq(dispatcher.queuedReturnDeadline(head), 0, "released head cleared");
        assertEq(dispatcher.responseQueueHead(), second, "second is the head");
        assertEq(dispatcher.queuedReturnDeadline(second), secondDeadline, "second keeps its deadline");
    }

    // ------------------------------------------------------------------ boundary and preconditions

    function testShouldRefuseAtTheDeadlineSecondAndReleaseOneSecondLater() public {
        (uint64 head, uint256 deadline) = _stuckReturn();

        vm.warp(deadline - 1);
        vm.expectRevert(abi.encodeWithSelector(ReturnNotExpired.selector, head, deadline));
        dispatcher.flushExpiredReturn();

        vm.warp(deadline);
        vm.expectRevert(abi.encodeWithSelector(ReturnNotExpired.selector, head, deadline));
        dispatcher.flushExpiredReturn();
        assertEq(dispatcher.queuedReturnDeadline(head), deadline, "refusal changes nothing");

        vm.warp(deadline + 1);
        assertTrue(dispatcher.flushExpiredReturn(), "allowed one second later");
        assertEq(dispatcher.responseQueueHead(), 0, "released");
    }

    function testShouldRefuseAHeadThatIsNotAReturnWithDeadlineZero() public {
        // A token-less head that cannot leave: a settlement receipt behind a failing router.
        router.setFailSend(address(dispatcher), true);
        _bridge(1e18);
        uint64 head = dispatcher.responseQueueHead();
        assertGt(head, 0, "the settlement receipt is queued");
        (CcipMsgType messageType, ) = _queuedPayload(head);
        assertEq(uint8(messageType), uint8(CcipMsgType.TRANSFER_SETTLED), "not a return");
        vm.warp(block.timestamp + 10 days);
        vm.expectRevert(abi.encodeWithSelector(ReturnNotExpired.selector, head, 0));
        dispatcher.flushExpiredReturn();
    }

    function testShouldRevertOnAnEmptyQueue() public {
        assertEq(dispatcher.responseQueueHead(), 0, "empty");
        vm.expectRevert(NoQueuedResponse.selector);
        dispatcher.flushExpiredReturn();
    }

    // ------------------------------------------------------------------ token-bearing attempt fails: exit without tokens

    function _assertReleasedWithoutTokens(uint64 head_, bytes32 operationId_) internal {
        vm.expectEmit(address(dispatcher));
        emit ReturnExpiredUnwound(operationId_, RECALL, head_);
        assertTrue(dispatcher.flushExpiredReturn(), "token-less exit");
        assertEq(dispatcher.responseQueueHead(), 0, "queue empty");
        assertEq(dispatcher.queuedTokenAmount(), 0, "queue bucket empty");
        assertEq(dispatcher.trackedIdle(), FUNDED, "tokens back to tracked idle");
        assertEq(token.balanceOf(address(dispatcher)), FUNDED, "no token left the dispatcher");
        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0), "the executor closed the recall");
    }

    function testShouldExitWithoutTokensOnTheRateLimit() public {
        (uint64 head, uint256 deadline) = _stuckReturn();
        bytes32 operationId = _returnOperationId(head);
        uint64 versionBefore = dispatcher.stateVersion();
        vm.warp(deadline + 1);
        _assertReleasedWithoutTokens(head, operationId);
        assertEq(dispatcher.stateVersion(), versionBefore, "stateVersion unchanged");
    }

    function testShouldExitWithoutTokensWhenOnlyTheTokenMessageExceedsTheFeeCeiling() public {
        (uint64 head, uint256 deadline) = _stuckReturn();
        bytes32 operationId = _returnOperationId(head);
        _unblockSends();
        _setRoute(true, 1 ether);
        router.setFee(0.1 ether);
        router.setTokenFee(2 ether);
        vm.deal(address(dispatcher), 5 ether);
        vm.warp(deadline + 1);
        _assertReleasedWithoutTokens(head, operationId);
        assertEq(address(dispatcher).balance, 4.9 ether, "only the token-less fee was paid");
    }

    function testShouldExitWithoutTokensWhenTheFeeBalanceCoversOnlyTheTokenlessMessage() public {
        (uint64 head, uint256 deadline) = _stuckReturn();
        bytes32 operationId = _returnOperationId(head);
        _unblockSends();
        router.setFee(0.1 ether);
        router.setTokenFee(5 ether);
        vm.deal(address(dispatcher), 1 ether);
        vm.warp(deadline + 1);
        _assertReleasedWithoutTokens(head, operationId);
        assertEq(address(dispatcher).balance, 0.9 ether, "only the token-less fee was paid");
    }

    function testShouldExitWithoutTokensOnACustomRouterError() public {
        (uint64 head, uint256 deadline) = _stuckReturn();
        bytes32 operationId = _returnOperationId(head);
        router.setFailSendWith(address(dispatcher), abi.encodeWithSelector(PoolDisabled.selector));
        vm.warp(deadline + 1);
        _assertReleasedWithoutTokens(head, operationId);
    }

    function testShouldExitWithoutTokensOnAStringRevertFromThePool() public {
        (uint64 head, uint256 deadline) = _stuckReturn();
        bytes32 operationId = _returnOperationId(head);
        router.setFailSendWith(address(dispatcher), abi.encodeWithSignature("Error(string)", "pool: not allowed"));
        vm.warp(deadline + 1);
        _assertReleasedWithoutTokens(head, operationId);
    }

    function testShouldSendWithTokensWhenTheAttemptSucceeds() public {
        (uint64 head, uint256 deadline) = _stuckReturn();
        _unblockSends();
        vm.warp(deadline + 1);
        assertFalse(dispatcher.flushExpiredReturn(), "left with its tokens");
        assertEq(dispatcher.queuedReturnDeadline(head), 0, "cleared");
        assertEq(token.balanceOf(address(dispatcher)), FUNDED - RECALL, "tokens left");
        assertEq(dispatcher.trackedIdle(), FUNDED - RECALL, "debit stays");
    }

    // ------------------------------------------------------------------ token-less send fails: the whole call reverts

    function _assertKeptAfterRevert(Snapshot memory before_, uint64 head_, uint256 deadline_) internal {
        assertEq(dispatcher.queuedReturnDeadline(head_), deadline_, "deadline kept");
        _assertSame(before_, _snapshot());
        // The same entry is still releasable once the cause is gone.
        router.clearTokenFee();
        router.setFee(0);
        _setRoute(true, FEE_CEILING);
        router.setFailSend(address(dispatcher), false);
        _blockTokenSends();
        assertTrue(dispatcher.flushExpiredReturn(), "released after the cause is gone");
    }

    function testShouldRevertWholeCallWhenTheTokenlessFeeExceedsTheCeiling() public {
        (uint64 head, , uint256 deadline) = _expiredWithEntryBehind();
        _setRoute(true, 1 ether);
        router.setFee(2 ether);
        router.setTokenFee(2 ether);
        vm.deal(address(dispatcher), 5 ether);
        Snapshot memory before_ = _snapshot();
        vm.expectRevert(abi.encodeWithSelector(CcipFeeTooHigh.selector, 2 ether, 1 ether));
        dispatcher.flushExpiredReturn();
        _assertKeptAfterRevert(before_, head, deadline);
    }

    function testShouldRevertWholeCallWhenTheFeeBalanceIsMissing() public {
        (uint64 head, , uint256 deadline) = _expiredWithEntryBehind();
        router.setFee(0.1 ether);
        Snapshot memory before_ = _snapshot();
        vm.expectRevert(abi.encodeWithSelector(CcipInsufficientNativeFeeBalance.selector, 0, 0.1 ether));
        dispatcher.flushExpiredReturn();
        assertEq(address(dispatcher).balance, 0, "no fee balance");
        _assertKeptAfterRevert(before_, head, deadline);
    }

    function testShouldRevertWholeCallWhenTheRouteIsDisabled() public {
        (uint64 head, , uint256 deadline) = _expiredWithEntryBehind();
        _setRoute(false, FEE_CEILING);
        Snapshot memory before_ = _snapshot();
        vm.expectRevert(abi.encodeWithSelector(CcipUnknownChain.selector, block.chainid));
        dispatcher.flushExpiredReturn();
        _assertKeptAfterRevert(before_, head, deadline);
    }

    function testShouldRevertWholeCallWhenTheRouterFailsEverySend() public {
        (uint64 head, , uint256 deadline) = _expiredWithEntryBehind();
        router.setFailSend(address(dispatcher), true);
        Snapshot memory before_ = _snapshot();
        vm.expectRevert(bytes("forced send failure"));
        dispatcher.flushExpiredReturn();
        _assertKeptAfterRevert(before_, head, deadline);
    }

    // ------------------------------------------------------------------ the zero return at the executor

    function testShouldCloseARecallWithAPositiveMinimumAsBelowMinimumCredited() public {
        _blockTokenSends();
        uint256 minReturn = 50e18;
        uint256 deadline = block.timestamp + _transferStalenessMax();
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, RECALL, minReturn, 0, address(0), ROUTE_GAS_LIMIT);
        uint64 head = dispatcher.responseQueueHead();
        assertEq(dispatcher.queuedReturnDeadline(head), deadline, "deadline kept for a recall with a minimum");
        bytes32 operationId = _returnOperationId(head);
        vm.warp(deadline + 1);
        vm.expectEmit(address(executor));
        emit ReturnBelowMinimumCredited(REMOTE_CHAIN, operationId, 0, minReturn);
        assertTrue(dispatcher.flushExpiredReturn(), "released");
        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0), "recall closed with nothing received");
    }
}

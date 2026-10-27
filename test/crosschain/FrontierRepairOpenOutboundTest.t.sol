// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipAppBase} from "../../contracts/crosschain/ccip/base/CcipAppBase.sol";
import {CcipExecutorFixture} from "./CcipExecutorFixture.sol";
import {BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {ResolveOutcome, CcipChainRescue} from "../../contracts/crosschain/lib/CrosschainConstants.sol";

/// @title StargateFrontierRepairOpenOutboundTest
/// @notice IL-8614 / TP-M-36 on Stargate. `ADVANCE_STATE_FRONTIER` skipping a lost `TRANSFER_SETTLED` leaves
///         `outboundInFlight` holding the amount; the next attestation, read at the repaired frontier with the
///         delivered amount already included, would be added on top of it: NAV = S + 2A (measured 120e6 vs a
///         true 110e6). The repair itself may run (it is the only exit from a stuck frontier); `approveBalance`
///         refuses to write `settled` while the repair latch is armed and the outbound value is still open.
contract StargateFrontierRepairOpenOutboundTest is CrosschainTestBase {
    bytes32 internal constant LATE_SETTLEMENT_CREDITED =
        keccak256("LateSettlementCredited(uint256,bytes32,uint256,uint256,uint64)");

    bytes32 internal transferId;
    bytes32 internal guid;

    function setUp() public {
        _baseSetUp();
        _readyDispatcher();
        _settle100(); // settled = 100e6, frontier 1
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(100e6, 1);
        // A = 10e6 reaches the dispatcher (true balance 110e6); its TRANSFER_SETTLED has not been applied.
        (transferId, guid,) = _sendAsset(10e6, 0);
    }

    function _propose(uint256 settledLD_, uint64 stateVersion_) internal returns (uint256) {
        BalanceObservation memory o = BalanceObservation({
            chainId: REMOTE_CHAIN,
            settledBalance: settledLD_,
            stateVersion: stateVersion_,
            remoteBlock: 1,
            remoteTimestamp: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 30 minutes),
            trackedPositionSetHash: bytes32(0)
        });
        vm.prank(proposer);
        executor.proposeBalance(o);
        return executor.proposalCount();
    }

    function _attest(uint256 settledLD_, uint64 stateVersion_) internal {
        uint256 pid = _propose(settledLD_, stateVersion_);
        vm.prank(approver);
        executor.approveBalance(pid);
    }

    function _advance(uint64 newVersion_) internal {
        bytes32 id = bytes32((uint256(REMOTE_CHAIN) << 64) | uint256(newVersion_));
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(id, ResolveOutcome.ADVANCE_STATE_FRONTIER);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceResolveTransfer(rescueId, id, ResolveOutcome.ADVANCE_STATE_FRONTIER);
    }

    function _resolveOutbound(ResolveOutcome outcome_) internal {
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(transferId, outcome_);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceResolveTransfer(rescueId, transferId, outcome_);
    }

    function _expectBlocked(uint64 stateVersion_) internal {
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _propose(110e6, stateVersion_);
        vm.prank(approver);
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.FrontierRepairBlockedByOpenTransfers.selector, REMOTE_CHAIN, 10e6)
        );
        executor.approveBalance(pid);
    }

    function _deliverSettledExternal(uint64 version_) external {
        _deliverTransferSettled(transferId, guid, 10e6, version_);
    }

    /// @dev (i) The settlement (version 2) is lost: the repair runs, but approving the S + 2A attestation reverts.
    function testApproveShouldRefuseWhileRepairLatchArmedAndOutboundOpen() public {
        _advance(2);
        assertTrue(executor.frontierRepairPending(REMOTE_CHAIN), "repair ran and armed the latch");
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 10e6, "outbound still open");

        _expectBlocked(2);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "settled untouched, no S + 2A");
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "chain stays blocked");
        assertTrue(executor.frontierRepairPending(REMOTE_CHAIN), "latch stays armed");
    }

    /// @dev (ii) Path a: the settlement is version 3 (version 2 was some other lost message), retained by the lane.
    ///      After the repair it replays, the record closes and the attestation then equals the true balance.
    function testRetainedSettleReplaysAfterRepairThenApproveEqualsTrueBalance() public {
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.StateVersionGap.selector, REMOTE_CHAIN, 2, 3));
        this._deliverSettledExternal(3);

        _advance(2);
        _expectBlocked(2);

        _deliverTransferSettled(transferId, guid, 10e6, 3);
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0, "record closed by the replayed settlement");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 110e6);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(110e6, 3);
        assertEq(executor.getBalance(), 110e6, "NAV == true remote balance");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "approval lifts the repair block");
    }

    /// @dev (iii) Path b: the settlement is truly lost; force-resolving the record unlocks the approval.
    function testNavShouldEqualTrueRemoteBalanceAfterDeliveredToSettledThenApprove() public {
        _advance(2);
        _expectBlocked(2);
        _resolveOutbound(ResolveOutcome.DELIVERED_TO_SETTLED);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 110e6, "force-resolve credited the delivered amount");
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(110e6, 2); // the dispatcher really holds 100 + 10

        assertEq(executor.getBalance(), 110e6, "NAV == true remote balance, not S + 2A");
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0);
    }

    function testNavShouldEqualTrueRemoteBalanceAfterDropFromNavThenApprove() public {
        _advance(2);
        _expectBlocked(2);
        _resolveOutbound(ResolveOutcome.DROP_FROM_NAV);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(110e6, 2);

        assertEq(executor.getBalance(), 110e6, "NAV == true remote balance");

        // IL-8619 review: the dropped record's settlement, whose version the repair skipped, lands after the
        // approval that already contains it. It is a duplicate at the frontier and must not be credited again.
        vm.recordLogs();
        _deliverTransferSettled(transferId, guid, 10e6, 2);
        assertEq(executor.getBalance(), 110e6, "skipped-version settlement not credited twice");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != LATE_SETTLEMENT_CREDITED, "no LateSettlementCredited");
        }
    }

    /// @dev (iv) With no outbound in flight the repair and the approval behave exactly as before.
    function testRepairWithNoOutboundInFlightIsUnchanged() public {
        _resolveOutbound(ResolveOutcome.DROP_FROM_NAV);
        _advance(2);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN));
        assertTrue(executor.frontierRepairPending(REMOTE_CHAIN));
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 2);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(110e6, 2);
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "approval lifts the block");
        assertFalse(executor.frontierRepairPending(REMOTE_CHAIN), "latch consumed");
    }

    /// @dev Without a repair latch an ordinary approval is not gated by an open outbound.
    function testOrdinaryApprovalIsNotGatedByOpenOutbound() public {
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(100e6, 1);
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 10e6);
    }
}

/// @title CcipFrontierRepairOpenOutboundTest
/// @notice IL-8614 / TP-M-36 on CCIP: same scenarios with a real dispatcher. The lost response is skipped through
///         `scheduleSkipStuckResponse`; the retained one is a held settlement behind a burned state version.
contract CcipFrontierRepairOpenOutboundTest is CcipExecutorFixture {
    bytes32 internal operationId;

    function setUp() public {
        _fixtureSetUp();
        _bridge(100e18);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(100e18);
    }

    /// @dev A = 10e18 reaches the dispatcher (stateVersion 2) but its TRANSFER_SETTLED response is dropped for good.
    function _openLostOutbound() internal {
        router.setFailSend(address(dispatcher), true);
        vm.recordLogs();
        _bridge(10e18);
        operationId = _captureOperationId();
        uint64 stuck = dispatcher.responseQueueHead();
        vm.prank(RESCUE_ADMIN);
        uint256 skipId = dispatcher.scheduleSkipStuckResponse(stuck);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        dispatcher.executeSkipStuckResponse(skipId, stuck);
        router.setFailSend(address(dispatcher), false);
    }

    /// @dev Burns one remote state version (a dropped recall response), then sends A = 10e18 whose settlement is
    ///      held back; delivering it reverts on the gap, so the lane retains it. Returns its held index.
    function _openRetainedOutbound() internal returns (uint256 settleIndex) {
        router.setFailSend(address(dispatcher), true);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 1e18, 0, 0, address(0), 500_000);
        uint64 stuck = dispatcher.responseQueueHead();
        vm.prank(RESCUE_ADMIN);
        uint256 skipId = dispatcher.scheduleSkipStuckResponse(stuck);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        dispatcher.executeSkipStuckResponse(skipId, stuck);
        router.setFailSend(address(dispatcher), false);
        executor.cancelPendingReturn(REMOTE_CHAIN);

        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
        vm.recordLogs();
        token.mint(address(executor), 10e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 10e18, 0, address(0), 500_000);
        operationId = _captureOperationId();
        router.deliverHeld(router.heldCount() - 1);
        settleIndex = router.heldCount() - 1;
        router.setHoldTokenMessages(false);
        router.setAutoDeliver(true);

        uint64 f = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainExecutor.StateVersionGap.selector, REMOTE_CHAIN, f + 1, f + 2)
        );
        router.deliverHeld(settleIndex);
    }

    function _advance(uint64 newVersion_) internal {
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.ADVANCE_FRONTIER, REMOTE_CHAIN, newVersion_);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.ADVANCE_FRONTIER, REMOTE_CHAIN, newVersion_);
    }

    function _resolveOutbound(bool credit_) internal {
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleForceResolveOutbound(operationId, credit_);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeForceResolveOutbound(rescueId, operationId, credit_);
    }

    function _expectBlocked() internal {
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _propose(dispatcher.accountedBalance());
        vm.prank(APPROVER);
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.FrontierRepairBlockedByOpenTransfers.selector, REMOTE_CHAIN, 10e18)
        );
        executor.approveBalance(pid);
    }

    /// @dev (i) The settlement is lost: the repair runs, but approving the S + 2A attestation reverts.
    function testApproveShouldRefuseWhileRepairLatchArmedAndOutboundOpen() public {
        _openLostOutbound();
        assertEq(dispatcher.accountedBalance(), 110e18, "the dispatcher really holds S + A");
        _advance(2);
        assertTrue(executor.frontierRepairPending(REMOTE_CHAIN), "repair ran and armed the latch");
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 10e18, "outbound still open");

        _expectBlocked();

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18, "settled untouched, no S + 2A");
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "chain stays blocked");
        assertTrue(executor.frontierRepairPending(REMOTE_CHAIN), "latch stays armed");
    }

    /// @dev (ii) Path a: the settlement is retained behind a lost version; after the repair it replays, the record
    ///      closes and the attestation equals the true balance.
    function testRetainedSettleReplaysAfterRepairThenApproveEqualsTrueBalance() public {
        uint256 settleIndex = _openRetainedOutbound();
        uint64 f = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        _advance(f + 1);

        _expectBlocked();

        router.deliverHeld(settleIndex);
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0, "record closed by the replayed settlement");

        _attest(dispatcher.accountedBalance());
        assertEq(executor.getBalance(), dispatcher.accountedBalance(), "NAV == true remote balance");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "approval lifts the repair block");
    }

    /// @dev (iii) Path b: the settlement is truly lost; force-resolving the record unlocks the approval.
    function testNavShouldEqualTrueRemoteBalanceAfterDeliveredToSettledThenApprove() public {
        _openLostOutbound();
        _advance(2);
        _expectBlocked();
        _resolveOutbound(true);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 110e18);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(110e18);

        assertEq(executor.getBalance(), 110e18, "NAV == true remote balance, not S + 2A");
        assertEq(executor.getBalance(), dispatcher.accountedBalance(), "invariant: NAV == dispatcher balance");
    }

    function testNavShouldEqualTrueRemoteBalanceAfterDropFromNavThenApprove() public {
        _openLostOutbound();
        _advance(2);
        _expectBlocked();
        _resolveOutbound(false);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(110e18);

        assertEq(executor.getBalance(), 110e18, "NAV == true remote balance");
        assertEq(executor.getBalance(), dispatcher.accountedBalance(), "invariant: NAV == dispatcher balance");
    }

    /// @dev (iv) With no outbound in flight the repair and the approval behave exactly as before.
    function testRepairWithNoOutboundInFlightIsUnchanged() public {
        _openLostOutbound();
        _resolveOutbound(false);
        _advance(2);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN));
        assertTrue(executor.frontierRepairPending(REMOTE_CHAIN));
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), 2);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(110e18);
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "approval lifts the block");
        assertFalse(executor.frontierRepairPending(REMOTE_CHAIN), "latch consumed");
    }

    /// @dev (v) IL-8619, the one case the skip is right. DROP_FROM_NAV on an outbound whose TRANSFER_SETTLED is merely
    ///      retained, and a frontier repair that advances over that settlement too: the latch-clearing approval, read
    ///      honestly at the repaired frontier, already contains the delivered amount, and the settlement's version is
    ///      not above the approval's. The late settlement must NOT be credited again (was S + 2A). A settlement with a
    ///      higher version is credited (`testDropFromNavThenForceSetThenLateSettleIsCredited`).
    function testDropFromNavThenAttestThenLateSettleIsNotCreditedAgain() public {
        uint256 settleIndex = _openRetainedOutbound();
        uint64 f = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        _resolveOutbound(false);
        _advance(f + 2); // over the burnt version and over A's retained settlement

        assertEq(dispatcher.stateVersion(), executor.lastRemoteStateVersion(REMOTE_CHAIN), "observation at frontier");
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(dispatcher.accountedBalance()); // outbound is closed, so approval is allowed: settled = S + A
        assertEq(executor.getBalance(), dispatcher.accountedBalance());

        router.deliverHeld(settleIndex); // the retained settlement arrives late, at a version the approval covered
        assertEq(executor.getBalance(), dispatcher.accountedBalance(), "late settle skipped: NAV == true balance");
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0);
    }

    // ---- IL-8619: late settlement after DROP_FROM_NAV ----

    /// @dev A = 10e18 reaches the dispatcher and its TRANSFER_SETTLED (the next version, no gap) is held back, so it
    ///      can be delivered at will. Returns its held index.
    function _openHeldOutbound() internal returns (uint256 settleIndex) {
        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
        vm.recordLogs();
        token.mint(address(executor), 10e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 10e18, 0, address(0), 500_000);
        operationId = _captureOperationId();
        router.deliverHeld(router.heldCount() - 1);
        settleIndex = router.heldCount() - 1;
        router.setHoldTokenMessages(false);
        router.setAutoDeliver(true);
    }

    /// @dev A = 10e18 sent; its token message is held before the dispatcher chain executes it, so the dispatcher does
    ///      not hold A yet. Returns the held index of the token message.
    function _openUndeliveredOutbound() internal returns (uint256 tokenIndex) {
        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
        vm.recordLogs();
        token.mint(address(executor), 10e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 10e18, 0, address(0), 500_000);
        operationId = _captureOperationId();
        tokenIndex = router.heldCount() - 1;
        router.setHoldTokenMessages(false);
        router.setAutoDeliver(true);
    }

    /// @dev DROP -> routine version-bound approval of S (honest: it cannot contain A, which rides the next version)
    ///      -> late settle is CREDITED; NAV = S + A and the next honest S + A attestation passes.
    function testDropFromNavThenRoutineApprovalThenLateSettleIsCredited() public {
        uint256 settleIndex = _openHeldOutbound();
        _resolveOutbound(false);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(100e18);
        assertEq(executor.getBalance(), 100e18);

        router.deliverHeld(settleIndex);
        assertEq(executor.getBalance(), dispatcher.accountedBalance(), "NAV == S + A");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 110e18, "credited once");

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(dispatcher.accountedBalance()); // inside the anchor band
        assertEq(executor.getBalance(), dispatcher.accountedBalance());
    }

    /// @dev DROP -> force-set -> late settle is CREDITED (IL-8619 review). A's token message is not executed on the
    ///      dispatcher chain yet, so the honest, version-bound force-set reads S; A is credited at the next version,
    ///      after the force-set, and its settlement is booked once (it used to be skipped, which left NAV at S).
    function testDropFromNavThenForceSetThenLateSettleIsCredited() public {
        uint256 tokenIndex = _openUndeliveredOutbound();
        _resolveOutbound(false);
        vm.warp(block.timestamp + 1); // IL-8604 R1: read strictly after the last value-moving receipt
        assertEq(dispatcher.stateVersion(), executor.lastRemoteStateVersion(REMOTE_CHAIN), "observation at frontier");
        assertEq(dispatcher.accountedBalance(), 100e18, "A is not on the dispatcher yet");
        uint256 arg = (uint256(executor.lastRemoteStateVersion(REMOTE_CHAIN)) << 192) |
            (block.timestamp << 128) | 100e18;
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18);

        router.deliverHeld(tokenIndex); // A is executed on the dispatcher chain; its settlement follows
        assertEq(dispatcher.accountedBalance(), 110e18, "the dispatcher holds A");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 110e18, "credited once");
        assertEq(executor.getBalance(), dispatcher.accountedBalance());
    }

    function _lateSettle(uint256 settleIndex_) internal {
        router.deliverHeld(settleIndex_);
    }

    /// @dev The `messageId` of the (single) `CcipMessageReceived` the executor emitted since `vm.recordLogs()`.
    function _executorReceivedMessageId() internal returns (bytes32 messageId) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(executor) && logs[i].topics[0] == CcipAppBase.CcipMessageReceived.selector) {
                (messageId, , ) = abi.decode(logs[i].data, (bytes32, uint256, address));
                ++found;
            }
        }
        assertEq(found, 1, "exactly one executor receipt");
    }

    /// @dev (a)+(b) no attestation in between: credited once by min(received, amount); NAV == true balance.
    function testLateSettleAfterDropFromNavWithoutAttestationIsCreditedOnce() public {
        uint256 settleIndex = _openRetainedOutbound();
        uint64 f = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        _resolveOutbound(false);
        _advance(f + 1);
        uint256 before = executor.settledRemoteBalance(REMOTE_CHAIN);

        vm.recordLogs();
        _lateSettle(settleIndex);
        bytes32 messageId = _executorReceivedMessageId();
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), before + 10e18, "credited once");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), dispatcher.accountedBalance(), "settled == true balance");
        assertTrue(executor.processedCcipMessage(messageId), "first delivery marked processed");

        // a duplicate delivery of the same message id reverts on the replay guard and changes nothing
        vm.expectRevert(abi.encodeWithSelector(CcipAppBase.CcipMessageAlreadyProcessed.selector, messageId));
        router.deliverHeld(settleIndex);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), dispatcher.accountedBalance());
    }

    /// @dev (c) DELIVERED_TO_SETTLED booked the credit, so the late settlement is a no-op (no double credit).
    function testLateSettleAfterDeliveredToSettledIsNoOp() public {
        uint256 settleIndex = _openRetainedOutbound();
        uint64 f = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        _resolveOutbound(true);
        _advance(f + 1);
        uint256 before = executor.settledRemoteBalance(REMOTE_CHAIN);

        _lateSettle(settleIndex);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), before, "no double credit");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), dispatcher.accountedBalance(), "settled == true balance");
    }
}

/// @title CcipLateSettlementZeroBaselineTest
/// @notice IL-8619: with S = 0 a routine 0 -> 0 approval after DROP_FROM_NAV must not stop the late credit, otherwise
///         the next honest S + A attestation is `UnanchoredAttestation`.
contract CcipLateSettlementZeroBaselineTest is CcipExecutorFixture {
    function setUp() public {
        _fixtureSetUp();
    }

    function testZeroBaselineRoutineApprovalThenLateSettleIsCredited() public {
        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
        vm.recordLogs();
        token.mint(address(executor), 10e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 10e18, 0, address(0), 500_000);
        bytes32 operationId = _captureOperationId();
        router.deliverHeld(router.heldCount() - 1);
        uint256 settleIndex = router.heldCount() - 1;
        router.setHoldTokenMessages(false);
        router.setAutoDeliver(true);

        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleForceResolveOutbound(operationId, false);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeForceResolveOutbound(rescueId, operationId, false);

        _attest(0); // 0 -> 0, version-bound
        assertEq(executor.getBalance(), 0);

        router.deliverHeld(settleIndex);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 10e18, "credited");

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(dispatcher.accountedBalance()); // anchored, no UnanchoredAttestation
        assertEq(executor.getBalance(), dispatcher.accountedBalance());
    }
}

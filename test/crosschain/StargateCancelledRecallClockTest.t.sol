// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {ResolveOutcome} from "../../contracts/crosschain/lib/CrosschainConstants.sol";

/// @title StargateCancelledRecallClockTest
/// @notice IL-8621 (Ackee TP-M-43): the permissionless `cancelStaleReturnRequest` frees the request slot and the
///         staleness slot, but the dispatcher may already have bridged the recall. The chain keeps a
///         cancelled-recall clock armed (parity with CCIP IL-8590) so `getBalance` cannot keep pricing the
///         pre-return `settled` on a recent attestation while the return legs are still in flight.
contract StargateCancelledRecallClockTest is CrosschainTestBase {
    function setUp() public {
        _baseSetUp();
        _readyDispatcher();
        _settle100(); // settled = 100e6, frontier = 1
        _refresh(100e6, 1);
    }

    function _refresh(uint256 settledLD_, uint64 version_) internal {
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        BalanceObservation memory o = BalanceObservation({
            chainId: REMOTE_CHAIN,
            settledBalance: settledLD_,
            stateVersion: version_,
            remoteBlock: 1,
            remoteTimestamp: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 20 minutes),
            trackedPositionSetHash: bytes32(0)
        });
        vm.prank(proposer);
        executor.proposeBalance(o);
        uint256 pid = executor.proposalCount();
        vm.prank(approver);
        executor.approveBalance(pid);
    }

    /// @dev Request 40e6, let the recall go stale and cancel it permissionlessly (no leg arrived).
    function _requestAndCancel() internal returns (bytes32 requestId, uint64 createdAt) {
        (requestId,,) = _requestAssets(40e6, 0);
        createdAt = uint64(block.timestamp);
        vm.warp(block.timestamp + TRANSFER_STALENESS_MAX + 1);
        executor.cancelStaleReturnRequest(REMOTE_CHAIN);
    }

    function _clock() internal view returns (uint32 count, uint64 pendingAt, uint32 generation, uint64 version) {
        return executor.cancelledRecallClock(REMOTE_CHAIN);
    }

    function _expectTransferStale() internal {
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavTransferStale.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    /// @dev Move the frontier past the cancel-time version with a value-moving message (an outbound that settles at
    ///      version `version_`) and price it with a fresh attestation bound to that version.
    function _advanceAndApprove(uint64 version_, uint256 settledLD_) internal {
        (bytes32 id, bytes32 guid,) = _sendAsset(1e6, 0);
        _deliverTransferSettled(id, guid, 1e6, version_);
        _refresh(settledLD_, version_);
    }

    function _forceResolve(bytes32 id_, ResolveOutcome outcome_) internal {
        vm.prank(admin);
        uint256 rid = executor.scheduleForceResolveTransfer(id_, outcome_);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceResolveTransfer(rid, id_, outcome_);
    }

    /// @notice Before the fix the cancel released the only clock and a recent attestation at the old version kept
    ///         pricing `settled`; now the window is bounded: the slot is free, the clock is not.
    function testCancelFreesSlotButKeepsClockAndNavFailsClosed() public {
        (, uint64 createdAt) = _requestAndCancel();
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 0, "capacity handed back");
        (uint32 count, uint64 pendingAt,, uint64 version) = _clock();
        assertEq(count, 1, "one cancelled recall");
        assertEq(pendingAt, createdAt, "clock keeps the request's createdAt");
        assertEq(version, 1, "cancel-time frontier recorded");

        // A recent truthful attestation at the OLD version keeps `settled` fresh but does not clear the clock.
        _refresh(100e6, 1);
        (count,,,) = _clock();
        assertEq(count, 1, "attestation at the cancel-time version does not clear");
        _expectTransferStale();

        // The slot is reusable meanwhile (liveness), and the clock still holds after another window.
        _requestAssets(10e6, 0);
        vm.warp(block.timestamp + STALENESS_MAX - 1);
        _refresh(100e6, 1);
        _expectTransferStale();
    }

    /// @notice An approval bound to a version past the cancel-time frontier clears the clock.
    function testApprovalPastCancelVersionClearsClock() public {
        _requestAndCancel();
        _advanceAndApprove(2, 101e6);
        (uint32 count, uint64 pendingAt, uint32 generation,) = _clock();
        assertEq(count, 0, "cleared");
        assertEq(pendingAt, 0, "clock gone");
        assertEq(generation, 1, "generation bumped");
        assertEq(executor.getBalance(), 101e6, "NAV priced again");
    }

    /// @notice A late compose for the cancelled request clears the clock (the value leg is booked and re-clocked).
    function testLateComposeClearsClock() public {
        (bytes32 requestId,) = _requestAndCancel();
        _refresh(100e6, 1);
        _expectTransferStale();
        usdc.mint(address(executor), 40e6);
        _deliverReturnCompose(requestId, RGUID, 40e6);
        (uint32 count, uint64 pendingAt,,) = _clock();
        assertEq(count, 0, "cleared by the compose leg");
        assertEq(pendingAt, 0, "clock gone");
        assertEq(executor.pendingArrivalReserve(), 40e6, "reserve booked");
        assertEq(executor.getBalance(), 100e6, "fresh re-armed record clock");
    }

    /// @notice A late RETURN_STARTED for the cancelled request clears the clock.
    function testLateMetadataClearsClock() public {
        (bytes32 requestId,) = _requestAndCancel();
        _refresh(100e6, 1);
        _expectTransferStale();
        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 2);
        (uint32 count, uint64 pendingAt,,) = _clock();
        assertEq(count, 0, "cleared by the metadata leg");
        assertEq(pendingAt, 0, "clock gone");
        assertEq(executor.returnInFlight(REMOTE_CHAIN), 40e6, "value booked in flight");
        assertEq(executor.getBalance(), 100e6, "fresh re-armed record clock");
    }

    /// @notice A dispatcher rejection of the cancelled request clears the clock.
    function testRejectionClearsClock() public {
        (bytes32 requestId,) = _requestAndCancel();
        _deliverReturnRejected(requestId);
        (uint32 count, uint64 pendingAt,,) = _clock();
        assertEq(count, 0, "cleared by the rejection");
        assertEq(pendingAt, 0, "clock gone");
        _refresh(100e6, 1);
        assertEq(executor.getBalance(), 100e6, "NAV reopened");
    }

    /// @notice A timelocked DROP_FROM_NAV of a cancelled record that never saw a leg finalizes it and clears the clock.
    function testForceResolveDropFromNavClearsClock() public {
        (bytes32 requestId,) = _requestAndCancel();
        _forceResolve(requestId, ResolveOutcome.DROP_FROM_NAV);
        (uint32 count, uint64 pendingAt,,) = _clock();
        assertEq(count, 0, "cleared by the drop");
        assertEq(pendingAt, 0, "clock gone");
    }

    /// @notice A RETURN_STARTED ahead of the frontier (after ADVANCE_STATE_FRONTIER) is rejected as a state-version
    ///         gap and does not touch the clock generation or the newer cancel's clock.
    function testDroppedReturnStartedAheadOfFrontierKeepsGeneration() public {
        _requestAndCancel();
        _forceResolve(bytes32((uint256(REMOTE_CHAIN) << 64) | uint256(2)), ResolveOutcome.ADVANCE_STATE_FRONTIER);
        _refresh(100e6, executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN)); // clears the repair latch
        (bytes32 b, uint64 createdB) = _requestAndCancel();
        (uint32 count, uint64 pendingAt, uint32 generation,) = _clock();
        assertEq(count, 1, "only the newer cancel");
        assertEq(generation, 1, "generation after the reset");
        assertEq(pendingAt, createdB, "newer clock");

        uint64 acked = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        uint64 ahead = acked + 5;
        // The gap is rejected before any accounting (the packet stays retained), so the clock is untouched.
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.StateVersionGap.selector, REMOTE_CHAIN, acked + 1, ahead)
        );
        _deliverReturnStarted(b, keccak256("b"), 40e6, 40e6, ahead);
        (count, pendingAt, generation,) = _clock();
        assertEq(count, 1, "dropped leg did not clear");
        assertEq(generation, 1, "generation intact");
        assertEq(pendingAt, createdB, "newer clock intact");
    }

    /// @notice Two cancels at different versions: an approval above the first cancel's version but at or below the
    ///         latest one does not clear; one above the latest does.
    function testApprovalBetweenCancelVersionsDoesNotClear() public {
        _requestAndCancel(); // cancel-time version 1
        (bytes32 id, bytes32 guid,) = _sendAsset(1e6, 0);
        _deliverTransferSettled(id, guid, 1e6, 2); // frontier 2, no approval, clock stays
        _requestAndCancel(); // latest cancel-time version 2
        (uint32 count,,, uint64 version) = _clock();
        assertEq(count, 2, "two cancelled recalls");
        assertEq(version, 2, "latest cancel version recorded");

        _refresh(101e6, 2); // above the first cancel's version, not above the latest one
        (count,,,) = _clock();
        assertEq(count, 2, "approval at the latest cancel version does not clear");
        _expectTransferStale();

        _advanceAndApprove(3, 102e6);
        (count,,,) = _clock();
        assertEq(count, 0, "approval above the latest cancel version clears");
    }

    /// @notice ADVANCE_STATE_FRONTIER clears the clock and starts a new generation.
    function testAdvanceStateFrontierClearsClock() public {
        _requestAndCancel();
        _forceResolve(bytes32((uint256(REMOTE_CHAIN) << 64) | uint256(2)), ResolveOutcome.ADVANCE_STATE_FRONTIER);
        (uint32 count, uint64 pendingAt, uint32 generation,) = _clock();
        assertEq(count, 0, "cleared");
        assertEq(pendingAt, 0, "clock gone");
        assertEq(generation, 1, "generation bumped");
    }

    /// @notice The timelocked force-set overwrites `settled`, which supersedes the cancelled recall's value.
    function testForceSetSettledClearsClock() public {
        _requestAndCancel();
        uint64 v = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        vm.prank(admin);
        uint256 id = executor.scheduleForceSetSettledBalance(REMOTE_CHAIN, 100e6, v, _markFsObs(), false);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceSetSettledBalance(id, REMOTE_CHAIN, 100e6, v, fsObs, false);
        (uint32 count, uint64 pendingAt, uint32 generation,) = _clock();
        assertEq(count, 0, "cleared");
        assertEq(pendingAt, 0, "clock gone");
        assertEq(generation, 1, "generation bumped");
        // IL-8646: the force-set stamps its committed remote observation time, which is RESCUE_DELAY (3d) old against
        // STALENESS_MAX (1h) here, so NAV stays stale until an ordinary attestation restores freshness.
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavSettledStale.selector, REMOTE_CHAIN));
        executor.getBalance();
        _refresh(100e6, v);
        assertEq(executor.getBalance(), 100e6, "NAV open again");
    }

    /// @notice Two cancels without a reset: the clock keeps the OLDEST createdAt and lasts until both resolve.
    function testTwoCancelsKeepOldestClockUntilBothResolve() public {
        (bytes32 a, uint64 createdA) = _requestAndCancel();
        (bytes32 b,) = _requestAndCancel();
        (uint32 count, uint64 pendingAt,,) = _clock();
        assertEq(count, 2, "two cancelled recalls");
        assertEq(pendingAt, createdA, "oldest createdAt kept");

        usdc.mint(address(executor), 40e6);
        _deliverReturnCompose(a, RGUID, 40e6);
        (count, pendingAt,,) = _clock();
        assertEq(count, 1, "one left");
        assertEq(pendingAt, createdA, "clock not re-anchored");

        _deliverReturnRejected(b);
        (count, pendingAt,,) = _clock();
        assertEq(count, 0, "both resolved");
        assertEq(pendingAt, 0, "clock gone");
    }

    /// @notice Generation guard: an answer to a recall cancelled before a reset must not clear the newer clock.
    function testGenerationGuardKeepsNewerClockOnOlderAnswer() public {
        (bytes32 a,) = _requestAndCancel();
        _advanceAndApprove(2, 101e6); // reset: generation 1
        (bytes32 b, uint64 createdB) = _requestAndCancel();
        (uint32 count, uint64 pendingAt, uint32 generation,) = _clock();
        assertEq(count, 1, "only the newer cancel");
        assertEq(generation, 1, "new generation");
        assertEq(pendingAt, createdB, "newer clock");

        usdc.mint(address(executor), 40e6);
        _deliverReturnCompose(a, RGUID, 40e6); // late answer to the older generation
        (count, pendingAt,,) = _clock();
        assertEq(count, 1, "older answer ignored");
        assertEq(pendingAt, createdB, "newer clock intact");

        usdc.mint(address(executor), 40e6);
        _deliverReturnCompose(b, keccak256("b"), 40e6);
        (count, pendingAt,,) = _clock();
        assertEq(count, 0, "newer answer clears");
        assertEq(pendingAt, 0, "clock gone");
    }
}

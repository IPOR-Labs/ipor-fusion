// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {CcipExecutorFixture} from "./CcipExecutorFixture.sol";
import {BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {ExecutorInitParams} from "../../contracts/crosschain/interfaces/ICrosschainFactory.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {CcipChainRescue} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {StargateExecutorAttestationLib} from "../../contracts/crosschain/stargate/lib/StargateExecutorAttestationLib.sol";
import {CcipExecutorAttestationLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorAttestationLib.sol";

/// @title StargateForceSetObservationStampTest
/// @notice IL-8646 / TP-L-18 on Stargate. `forceSetSettled` used to stamp the EXECUTE time into
///         `lastApprovedObservedAt`, so a figure that had aged `RESCUE_DELAY` in the queue received a full extra
///         `STALENESS_MAX`. The remote observation time is now part of the schedule-time hash and is what gets
///         stamped; `lastApprovalAt` (rate limiting) stays on the local clock.
contract StargateForceSetObservationStampTest is CrosschainTestBase {
    uint256 internal constant MAX = 7 days; // production-like: STALENESS_MAX well above RESCUE_DELAY
    uint256 internal constant BAL = 100e6;

    function setUp() public {
        _baseSetUp();
        ExecutorInitParams memory p = _params();
        p.stalenessMax = MAX;
        executor = _deployExecutor(address(factory), p);
        vm.deal(address(executor), 100 ether);
        _readyDispatcher();
        _settle100(); // settled = 100e6, frontier = 1
    }

    function _schedule(uint64 observedAt_) internal returns (uint256 id) {
        vm.prank(admin);
        id = executor.scheduleForceSetSettledBalance(REMOTE_CHAIN, BAL, 1, observedAt_, false);
    }

    function _forceSet(uint64 observedAt_) internal {
        uint256 id = _schedule(observedAt_);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceSetSettledBalance(id, REMOTE_CHAIN, BAL, 1, observedAt_, false);
    }

    function _proposeAt(uint64 remoteTimestamp_) internal returns (uint256) {
        BalanceObservation memory o = BalanceObservation({
            chainId: REMOTE_CHAIN,
            settledBalance: BAL,
            stateVersion: 1,
            remoteBlock: 1,
            remoteTimestamp: remoteTimestamp_,
            expiry: uint64(block.timestamp + 30 minutes),
            trackedPositionSetHash: bytes32(0)
        });
        vm.prank(proposer);
        executor.proposeBalance(o);
        return executor.proposalCount();
    }

    function testShouldStampCommittedObservationNotExecuteTime() public {
        uint64 observedAt = uint64(block.timestamp - 1 days);
        _forceSet(observedAt);
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), observedAt, "freshness clock = committed remote time");
        assertEq(executor.lastApprovalAt(REMOTE_CHAIN), block.timestamp, "rate limiter = execute time");
        assertTrue(executor.lastApprovedObservedAt(REMOTE_CHAIN) != block.timestamp);
    }

    function testShouldBeFreshExactlyAtTheStalenessBoundary() public {
        _forceSet(uint64(block.timestamp - (MAX - RESCUE_DELAY))); // age at execute == MAX
        assertEq(executor.getBalance(), BAL, "fresh at the boundary");
        vm.warp(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavSettledStale.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    function testShouldBeStaleImmediatelyWhenObservationAgedPastTheMaxInTheQueue() public {
        _forceSet(uint64(block.timestamp - (MAX - RESCUE_DELAY) - 1));
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), BAL, "settled is still rebased");
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavSettledStale.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    function testScheduleShouldRejectInvalidObservationTimestamps() public {
        bytes memory stale = abi.encodeWithSelector(CrosschainErrors.ObservationStale.selector, REMOTE_CHAIN);
        vm.startPrank(admin);
        vm.expectRevert(stale);
        executor.scheduleForceSetSettledBalance(REMOTE_CHAIN, BAL, 1, uint64(block.timestamp + 1), false); // future
        vm.expectRevert(stale);
        // too old
        executor.scheduleForceSetSettledBalance(REMOTE_CHAIN, BAL, 1, uint64(block.timestamp - MAX - 1), false);
        vm.expectRevert(stale);
        executor.scheduleForceSetSettledBalance(REMOTE_CHAIN, BAL, 1, 0, false);
        // boundary ok
        executor.scheduleForceSetSettledBalance(REMOTE_CHAIN, BAL, 1, uint64(block.timestamp - MAX), false);
        executor.scheduleForceSetSettledBalance(REMOTE_CHAIN, BAL, 1, uint64(block.timestamp), false); // now ok
        vm.stopPrank();
    }

    function testExecuteShouldRejectATimestampOtherThanTheCommittedOne() public {
        uint64 observedAt = uint64(block.timestamp - 1 days);
        uint256 id = _schedule(observedAt);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ForceResolveCommitmentMismatch.selector, id));
        executor.executeForceSetSettledBalance(id, REMOTE_CHAIN, BAL, 1, uint64(block.timestamp), false);
    }

    function _scheduleFigure(uint256 figure_, uint64 observedAt_, bool allowOlder_) internal returns (uint256 id) {
        vm.prank(admin);
        id = executor.scheduleForceSetSettledBalance(REMOTE_CHAIN, figure_, 1, observedAt_, allowOlder_);
    }

    /// @dev Schedules a force-set of `figure_` from `committed_`, then lands an ordinary approval with the NEWER
    ///      observation `newer_` during the rescue window; returns the id with the window elapsed.
    function _scheduleThenApproveNewer(uint256 figure_, uint64 committed_, bool allowOlder_)
        internal
        returns (uint256 id, uint64 newer)
    {
        id = _scheduleFigure(figure_, committed_, allowOlder_);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL + 1);
        newer = uint64(block.timestamp);
        uint256 pid = _proposeAt(newer);
        vm.prank(approver);
        executor.approveBalance(pid);
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), newer, "ordinary approval moved the clock forward");
        vm.warp(block.timestamp + RESCUE_DELAY);
    }

    function testUncheckedForceSetShouldMoveTheFreshnessClockBackwardsToTheCommittedTime() public {
        uint64 committed = uint64(block.timestamp - 1 days);
        (uint256 id, uint64 newer) = _scheduleThenApproveNewer(BAL, committed, true);
        vm.prank(admin);
        executor.executeForceSetSettledBalance(id, REMOTE_CHAIN, BAL, 1, committed, true);
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), committed, "re-stamped with the committed time");
        assertLt(committed, newer, "the clock moved backwards (opted out on purpose)");
    }

    function testStrictForceSetShouldBeRefusedWhenANewerApprovalLandedInTheWindow() public {
        uint64 committed = uint64(block.timestamp - 1 days);
        (uint256 id, uint64 newer) = _scheduleThenApproveNewer(90e6, committed, false);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.ForceSetOlderThanApproved.selector, REMOTE_CHAIN, committed, newer)
        );
        executor.executeForceSetSettledBalance(id, REMOTE_CHAIN, 90e6, 1, committed, false);
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), newer, "clock kept");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), BAL, "settled figure kept");

        // A reschedule from a fresh read (>= lastApprovedObservedAt) succeeds.
        uint64 fresh = uint64(block.timestamp);
        uint256 id2 = _scheduleFigure(90e6, fresh, false);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceSetSettledBalance(id2, REMOTE_CHAIN, 90e6, 1, fresh, false);
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), fresh);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 90e6);
    }

    function testStrictForceSetShouldPassWhenTheWindowApprovalHasTheSameReadTime() public {
        uint64 readAt = uint64(block.timestamp);
        uint256 id = _scheduleFigure(90e6, readAt, false);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL + 1);
        uint256 pid = _proposeAt(readAt);
        vm.prank(approver);
        executor.approveBalance(pid);
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), readAt);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceSetSettledBalance(id, REMOTE_CHAIN, 90e6, 1, readAt, false);
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), readAt, "equal passes");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 90e6);
    }

    function testStrictForceSetShouldPassOnAChainWithoutAnyApproval() public {
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), 0, "no approval yet");
        _forceSet(uint64(block.timestamp - 1 days));
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), block.timestamp - RESCUE_DELAY - 1 days);
    }

    function testTheOptOutFlagShouldBeBoundByTheCommitment() public {
        uint64 committed = uint64(block.timestamp - 1 days);
        uint256 strictId = _scheduleFigure(BAL, committed, false);
        uint256 uncheckedId = _scheduleFigure(BAL, committed, true);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ForceResolveCommitmentMismatch.selector, strictId));
        executor.executeForceSetSettledBalance(strictId, REMOTE_CHAIN, BAL, 1, committed, true);
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.ForceResolveCommitmentMismatch.selector, uncheckedId)
        );
        executor.executeForceSetSettledBalance(uncheckedId, REMOTE_CHAIN, BAL, 1, committed, false);
        vm.stopPrank();
    }

    function testOrdinaryAttestationShouldRespectTheStampedClockAndRestoreFreshness() public {
        uint64 observedAt = uint64(block.timestamp - 1 days);
        _forceSet(observedAt);

        // rate limiter keeps the local clock: an immediate ordinary approval is too early.
        uint256 executedAt = block.timestamp;
        uint256 early = _proposeAt(uint64(block.timestamp));
        vm.prank(approver);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.MinUpdateIntervalNotMet.selector, executedAt, block.timestamp, MIN_UPDATE_INTERVAL
            )
        );
        executor.approveBalance(early);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL + 1);
        uint256 older = _proposeAt(observedAt - 1);
        vm.prank(approver);
        vm.expectRevert(
            abi.encodeWithSelector(
                StargateExecutorAttestationLib.ObservationOlderThanApproved.selector,
                REMOTE_CHAIN,
                observedAt - 1,
                observedAt
            )
        );
        executor.approveBalance(older);

        uint64 fresh = uint64(block.timestamp);
        uint256 pid = _proposeAt(fresh);
        vm.prank(approver);
        executor.approveBalance(pid);
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), fresh);
        vm.warp(block.timestamp + MAX);
        assertEq(executor.getBalance(), BAL, "fresh again");
    }

    function testOrdinaryAttestationShouldRestoreFreshnessAfterAnImmediatelyStaleForceSet() public {
        _forceSet(uint64(block.timestamp - (MAX - RESCUE_DELAY) - 1));
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavSettledStale.selector, REMOTE_CHAIN));
        executor.getBalance();
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL + 1);
        uint256 pid = _proposeAt(uint64(block.timestamp));
        vm.prank(approver);
        executor.approveBalance(pid);
        assertEq(executor.getBalance(), BAL);
    }
}

/// @title CcipForceSetObservationStampTest
/// @notice Same rule on the CCIP transport. The observation time rides in bits 128..191 of the
///         `FORCE_SET_SETTLED` argument: `(stateVersion << 192) | (observedAt << 128) | newSettledLD`.
contract CcipForceSetObservationStampTest is CcipExecutorFixture {
    uint256 internal constant BAL = 100e18;

    function setUp() public {
        _fixtureSetUp();
        _bridge(BAL);
        vm.warp(block.timestamp + 8 days);
    }

    function _arg(uint256 observedAt_) internal view returns (uint256) {
        return (uint256(executor.lastRemoteStateVersion(REMOTE_CHAIN)) << 192) | (observedAt_ << 128) | BAL;
    }

    function _forceSet(uint64 observedAt_) internal {
        uint256 arg = _arg(observedAt_);
        vm.prank(RESCUE_ADMIN);
        uint256 id = executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(id, CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
    }

    function _proposeAt(uint64 remoteTimestamp_) internal returns (uint256) {
        return executor.proposeBalance(
            REMOTE_CHAIN,
            BAL,
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            1,
            remoteTimestamp_,
            uint64(block.timestamp + 1 days),
            dispatcher.trackedPositionSetHash()
        );
    }

    function testShouldStampCommittedObservationNotExecuteTime() public {
        uint64 observedAt = uint64(block.timestamp - 1 days);
        _forceSet(observedAt);
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), observedAt, "freshness clock = committed remote time");
        assertTrue(executor.lastApprovedObservedAt(REMOTE_CHAIN) != block.timestamp);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), BAL);
    }

    function testShouldBeFreshExactlyAtTheStalenessBoundary() public {
        _forceSet(uint64(block.timestamp - (BALANCE_STALENESS_MAX - RESCUE_DELAY)));
        assertEq(executor.getBalance(), BAL, "fresh at the boundary");
        vm.warp(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorAttestationLib.ObservationStale.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    function testShouldBeStaleImmediatelyWhenObservationAgedPastTheMaxInTheQueue() public {
        _forceSet(uint64(block.timestamp - (BALANCE_STALENESS_MAX - RESCUE_DELAY) - 1));
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), BAL, "settled is still rebased");
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorAttestationLib.ObservationStale.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    function testScheduleShouldRejectInvalidObservationTimestamps() public {
        bytes memory stale = abi.encodeWithSelector(CcipExecutorAttestationLib.ObservationStale.selector, REMOTE_CHAIN);
        uint256 future = _arg(block.timestamp + 1);
        uint256 tooOld = _arg(block.timestamp - BALANCE_STALENESS_MAX - 1);
        uint256 zero = _arg(0);
        uint256 boundary = _arg(block.timestamp - BALANCE_STALENESS_MAX);
        uint256 current = _arg(block.timestamp);
        vm.startPrank(RESCUE_ADMIN);
        vm.expectRevert(stale);
        executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, future);
        vm.expectRevert(stale);
        executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, tooOld);
        vm.expectRevert(stale);
        executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, zero);
        executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, boundary);
        executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, current);
        vm.stopPrank();
    }

    function _argFor(uint256 observedAt_, uint256 figure_) internal view returns (uint256) {
        return (uint256(executor.lastRemoteStateVersion(REMOTE_CHAIN)) << 192) | (observedAt_ << 128) | figure_;
    }

    function _schedule(CcipChainRescue kind_, uint256 arg_) internal returns (uint256 id) {
        vm.prank(RESCUE_ADMIN);
        id = executor.scheduleChainRescue(kind_, REMOTE_CHAIN, arg_);
    }

    function _execute(uint256 id_, CcipChainRescue kind_, uint256 arg_) internal {
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(id_, kind_, REMOTE_CHAIN, arg_);
    }

    /// @dev Schedules `kind_` from `committed_`, lands an ordinary approval with the NEWER observation during the
    ///      rescue window, then lets the window elapse.
    function _scheduleThenApproveNewer(CcipChainRescue kind_, uint256 arg_)
        internal
        returns (uint256 id, uint64 newer)
    {
        id = _schedule(kind_, arg_);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL + 1);
        newer = uint64(block.timestamp);
        uint256 pid = _proposeAt(newer);
        vm.prank(APPROVER);
        executor.approveBalance(pid);
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), newer, "ordinary approval moved the clock forward");
        vm.warp(block.timestamp + RESCUE_DELAY);
    }

    function testUncheckedForceSetShouldMoveTheFreshnessClockBackwardsToTheCommittedTime() public {
        uint64 committed = uint64(block.timestamp - 1 days);
        uint256 arg = _arg(committed);
        (uint256 id, uint64 newer) = _scheduleThenApproveNewer(CcipChainRescue.FORCE_SET_SETTLED_UNCHECKED, arg);
        _execute(id, CcipChainRescue.FORCE_SET_SETTLED_UNCHECKED, arg);
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), committed, "re-stamped with the committed time");
        assertLt(committed, newer, "the clock moved backwards (opted out on purpose)");
    }

    function testStrictForceSetShouldBeRefusedWhenANewerApprovalLandedInTheWindow() public {
        uint64 committed = uint64(block.timestamp - 1 days);
        uint256 arg = _argFor(committed, 90e18);
        (uint256 id, uint64 newer) = _scheduleThenApproveNewer(CcipChainRescue.FORCE_SET_SETTLED, arg);
        vm.prank(RESCUE_ADMIN);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorAttestationLib.ForceSetOlderThanApproved.selector, REMOTE_CHAIN, committed, newer
            )
        );
        executor.executeChainRescue(id, CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), newer, "clock kept");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), BAL, "settled figure kept");

        // A reschedule from a fresh read (>= lastApprovedObservedAt) succeeds.
        uint64 fresh = uint64(block.timestamp);
        uint256 arg2 = _argFor(fresh, 90e18);
        uint256 id2 = _schedule(CcipChainRescue.FORCE_SET_SETTLED, arg2);
        vm.warp(block.timestamp + RESCUE_DELAY);
        _execute(id2, CcipChainRescue.FORCE_SET_SETTLED, arg2);
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), fresh);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 90e18);
    }

    function testStrictForceSetShouldPassWhenTheWindowApprovalHasTheSameReadTime() public {
        uint64 readAt = uint64(block.timestamp);
        uint256 arg = _argFor(readAt, 90e18);
        uint256 id = _schedule(CcipChainRescue.FORCE_SET_SETTLED, arg);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL + 1);
        uint256 pid = _proposeAt(readAt);
        vm.prank(APPROVER);
        executor.approveBalance(pid);
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), readAt);
        vm.warp(block.timestamp + RESCUE_DELAY);
        _execute(id, CcipChainRescue.FORCE_SET_SETTLED, arg);
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), readAt, "equal passes");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 90e18);
    }

    function testStrictForceSetShouldPassOnAChainWithoutAnyApproval() public {
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), 0, "no approval yet");
        uint64 observedAt = uint64(block.timestamp - 1 days);
        _forceSet(observedAt);
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), observedAt);
    }

    function testTheKindShouldBeBoundByTheCommitment() public {
        uint256 arg = _arg(uint64(block.timestamp - 1 days));
        uint256 strictId = _schedule(CcipChainRescue.FORCE_SET_SETTLED, arg);
        uint256 uncheckedId = _schedule(CcipChainRescue.FORCE_SET_SETTLED_UNCHECKED, arg);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.startPrank(RESCUE_ADMIN);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ForceResolveCommitmentMismatch.selector, strictId));
        executor.executeChainRescue(strictId, CcipChainRescue.FORCE_SET_SETTLED_UNCHECKED, REMOTE_CHAIN, arg);
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.ForceResolveCommitmentMismatch.selector, uncheckedId)
        );
        executor.executeChainRescue(uncheckedId, CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        vm.stopPrank();
    }

    function testUncheckedKindShouldApplyTheSameScheduleChecks() public {
        bytes memory stale = abi.encodeWithSelector(CcipExecutorAttestationLib.ObservationStale.selector, REMOTE_CHAIN);
        uint256 tooOld = _arg(block.timestamp - BALANCE_STALENESS_MAX - 1);
        vm.startPrank(RESCUE_ADMIN);
        vm.expectRevert(stale);
        executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED_UNCHECKED, REMOTE_CHAIN, tooOld);
        vm.stopPrank();
    }

    function testOrdinaryAttestationShouldRespectTheStampedClockAndRestoreFreshness() public {
        uint64 observedAt = uint64(block.timestamp - 1 days);
        _forceSet(observedAt);

        uint256 executedAt = block.timestamp;
        vm.warp(block.timestamp + 1); // the observation must be strictly later than the force-set receipt
        uint256 early = _proposeAt(uint64(block.timestamp));
        vm.prank(APPROVER);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorAttestationLib.MinUpdateIntervalNotMet.selector,
                executedAt,
                block.timestamp,
                MIN_UPDATE_INTERVAL
            )
        );
        executor.approveBalance(early);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL + 1);
        // CCIP's value-moving-receipt gate (IL-8604), armed by the force-set at execute time, fires at propose time
        // and before the IL-8631 clock gate: an observation older than the force-set execution is refused either way.
        bytes32 setHash = dispatcher.trackedPositionSetHash();
        uint64 version = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        uint64 expiry = uint64(block.timestamp + 1 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorAttestationLib.ObservationPredatesValueMovingReceipt.selector,
                REMOTE_CHAIN,
                observedAt - 1,
                executedAt
            )
        );
        executor.proposeBalance(REMOTE_CHAIN, BAL, version, 1, observedAt - 1, expiry, setHash);

        uint64 fresh = uint64(block.timestamp);
        uint256 pid = _proposeAt(fresh);
        vm.prank(APPROVER);
        executor.approveBalance(pid);
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), fresh);
        vm.warp(block.timestamp + BALANCE_STALENESS_MAX);
        assertEq(executor.getBalance(), BAL, "fresh again");
    }

    function testOrdinaryAttestationShouldRestoreFreshnessAfterAnImmediatelyStaleForceSet() public {
        _forceSet(uint64(block.timestamp - (BALANCE_STALENESS_MAX - RESCUE_DELAY) - 1));
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorAttestationLib.ObservationStale.selector, REMOTE_CHAIN));
        executor.getBalance();
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL + 1);
        uint256 pid = _proposeAt(uint64(block.timestamp));
        vm.prank(APPROVER);
        executor.approveBalance(pid);
        assertEq(executor.getBalance(), BAL);
    }
}

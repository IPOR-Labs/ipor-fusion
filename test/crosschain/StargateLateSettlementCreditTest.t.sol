// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {ResolveOutcome} from "../../contracts/crosschain/lib/CrosschainConstants.sol";

/// @title StargateLateSettlementBase
/// @notice Shared helpers for the IL-8619 (Ackee TP-M-41) late-settlement tests: a genuine TRANSFER_SETTLED arriving
///         after a DROP_FROM_NAV rescue is credited once, also after the frontier-repair latch-clearing approval or a
///         force-set (IL-8619 review): every such write is bound to the frontier, so it cannot contain the delivered
///         amount, which rides a later state version.
abstract contract StargateLateSettlementBase is CrosschainTestBase {
    event LateSettlementCredited(
        uint256 srcChainId, bytes32 transferId, uint256 amountSD, uint256 credited, uint64 stateVersion
    );
    event LateSettlementAlreadyAttested(uint256 srcChainId, bytes32 transferId, uint64 stateVersion);
    event TransferSettlementConsumedWithoutAccounting(uint256 srcChainId, bytes32 transferId, uint64 stateVersion);

    bytes32 internal transferId;
    bytes32 internal guid;

    /// @dev NAV buckets for the chain (the rescue delay makes `getBalance` stale, which is orthogonal here).
    function _nav() internal view returns (uint256) {
        return executor.settledRemoteBalance(REMOTE_CHAIN) + executor.outboundInFlight(REMOTE_CHAIN);
    }

    function _resolve(ResolveOutcome outcome_) internal {
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(transferId, outcome_);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceResolveTransfer(rescueId, transferId, outcome_);
    }

    function _attest(uint256 settledLD_, uint64 stateVersion_) internal {
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
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
        uint256 pid = executor.proposalCount();
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

    function _forceSet(uint256 settledLD_) internal {
        uint64 observed = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceSetSettledBalance(
            REMOTE_CHAIN, settledLD_, observed, _markFsObs(), false
        );
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceSetSettledBalance(rescueId, REMOTE_CHAIN, settledLD_, observed, fsObs, false);
    }
}

/// @title StargateLateSettlementCreditTest
/// @notice Baseline S = 100e6 attested at version 1, then A = 10e6 sent (true remote balance 110e6).
contract StargateLateSettlementCreditTest is StargateLateSettlementBase {
    function setUp() public {
        _baseSetUp();
        _readyDispatcher();
        _settle100(); // settled = anchor = 100e6, frontier 1
        _attest(100e6, 1);
        (transferId, guid,) = _sendAsset(10e6, 0); // true remote balance becomes 110e6
    }

    /// @dev (a) + (b): credit once, NAV == true balance, duplicate is a no-op.
    function testLateSettleAfterDropFromNavIsCreditedOnce() public {
        _resolve(ResolveOutcome.DROP_FROM_NAV);
        assertEq(_nav(), 100e6, "dropped from NAV");

        vm.expectEmit(address(executor));
        emit LateSettlementCredited(REMOTE_CHAIN, transferId, 10e6, 10e6, 2);
        _deliverTransferSettled(transferId, guid, 10e6, 2);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 110e6);
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 110e6, "anchor credited");
        assertEq(_nav(), 110e6, "NAV == true balance");

        // (b) a re-delivery (older version) and a replay with a fresh version are both no-ops
        _deliverTransferSettled(transferId, guid, 10e6, 2);
        vm.expectEmit(address(executor));
        emit TransferSettlementConsumedWithoutAccounting(REMOTE_CHAIN, transferId, 3);
        _deliverTransferSettled(transferId, guid, 10e6, 3);
        assertEq(_nav(), 110e6, "credited exactly once");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 110e6);
    }

    /// @dev (c) DELIVERED_TO_SETTLED already booked the credit.
    function testLateSettleAfterDeliveredToSettledIsNoOp() public {
        _resolve(ResolveOutcome.DELIVERED_TO_SETTLED);
        assertEq(_nav(), 110e6);
        vm.expectEmit(address(executor));
        emit TransferSettlementConsumedWithoutAccounting(REMOTE_CHAIN, transferId, 2);
        _deliverTransferSettled(transferId, guid, 10e6, 2);
        assertEq(_nav(), 110e6, "no double credit");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 110e6);
    }

    /// @dev (d) The real IL-8614 sequence, read honestly: an unrelated version 2 is lost -> ADVANCE_STATE_FRONTIER(2)
    ///      -> DROP_FROM_NAV -> the latch-clearing approval reads S under version 2 (A rides version 3, so it is not
    ///      there yet) -> A's TRANSFER_SETTLED at version 3 is credited once (IL-8619 review: it used to be skipped,
    ///      which left NAV at S).
    function testLateSettleAfterRepairApprovalIsCredited() public {
        _advance(2);
        _resolve(ResolveOutcome.DROP_FROM_NAV);
        assertTrue(executor.frontierRepairPending(REMOTE_CHAIN), "repair latch armed");
        _attest(100e6, 2);
        assertFalse(executor.frontierRepairPending(REMOTE_CHAIN), "latch cleared by the approval");
        assertEq(_nav(), 100e6);

        vm.expectEmit(address(executor));
        emit LateSettlementCredited(REMOTE_CHAIN, transferId, 10e6, 10e6, 3);
        _deliverTransferSettled(transferId, guid, 10e6, 3);

        assertEq(_nav(), 110e6, "NAV == S + A");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 110e6, "anchor carries A");
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 3, "version consumed");

        // closed: a replay credits nothing
        _deliverTransferSettled(transferId, guid, 10e6, 4);
        assertEq(_nav(), 110e6);
    }

    /// @dev (d2) A routine, version-bound approval after the drop reads S only (the dispatcher's A rides version 2),
    ///      so it does not block the late credit; NAV ends at S + A and the next honest S + A attestation passes.
    function testLateSettleAfterRoutineApprovalIsCredited() public {
        _resolve(ResolveOutcome.DROP_FROM_NAV);
        _attest(100e6, 1);
        assertEq(_nav(), 100e6);

        vm.expectEmit(address(executor));
        emit LateSettlementCredited(REMOTE_CHAIN, transferId, 10e6, 10e6, 2);
        _deliverTransferSettled(transferId, guid, 10e6, 2);

        assertEq(_nav(), 110e6, "NAV == S + A");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 110e6, "anchor carries A");
        _attest(110e6, 2); // the honest attestation stays inside the anchor band
        assertEq(_nav(), 110e6);
    }

    /// @dev (d3) A force-set after the drop rebases settled and the anchor. Bound to version 1, it reads S only (A rides
    ///      version 2), so the late settlement is credited once (IL-8619 review: it used to be skipped). Never add an
    ///      in-transit amount to a force-set: it would be counted again here.
    function testLateSettleAfterForceSetIsCredited() public {
        _resolve(ResolveOutcome.DROP_FROM_NAV);
        _forceSet(100e6);
        assertEq(_nav(), 100e6);

        vm.expectEmit(address(executor));
        emit LateSettlementCredited(REMOTE_CHAIN, transferId, 10e6, 10e6, 2);
        _deliverTransferSettled(transferId, guid, 10e6, 2);

        assertEq(_nav(), 110e6, "NAV == S + A");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 110e6, "anchor carries A");
    }

    /// @dev (e) partial delivery credits the received amount.
    function testLateSettleCreditsReceivedWhenBelowAmount() public {
        _resolve(ResolveOutcome.DROP_FROM_NAV);
        vm.expectEmit(address(executor));
        emit LateSettlementCredited(REMOTE_CHAIN, transferId, 10e6, 9e6, 2);
        _deliverTransferSettled(transferId, guid, 9e6, 2);
        assertEq(_nav(), 109e6);
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 109e6);
    }

    /// @dev A peer reporting more than was sent is clamped to the recorded amount.
    function testLateSettleIsClampedToRecordedAmount() public {
        _resolve(ResolveOutcome.DROP_FROM_NAV);
        _deliverTransferSettled(transferId, guid, 50e6, 2);
        assertEq(_nav(), 110e6);
    }

    /// @dev A wrong guid never credits and never reverts (the lane must stay unbricked).
    function testLateSettleWithWrongGuidIsNotCredited() public {
        _resolve(ResolveOutcome.DROP_FROM_NAV);
        _deliverTransferSettled(transferId, bytes32(uint256(1)), 10e6, 2);
        assertEq(_nav(), 100e6);
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 2);
    }
}

/// @title StargateLateSettlementZeroBaselineTest
/// @notice S = 0 at the drop: a routine 0 -> 0 approval must not stop the late credit, otherwise the next honest
///         S + A attestation hits `UnanchoredAttestation` (the original Ackee repro).
contract StargateLateSettlementZeroBaselineTest is StargateLateSettlementBase {
    function setUp() public {
        _baseSetUp();
        _readyDispatcher();
        (transferId, guid,) = _sendAsset(10e6, 0); // nothing settled yet; true remote balance 10e6
    }

    function testZeroBaselineRoutineApprovalThenLateSettleIsCredited() public {
        _resolve(ResolveOutcome.DROP_FROM_NAV);
        _attest(0, 0); // 0 -> 0, version-bound
        assertEq(_nav(), 0);

        _deliverTransferSettled(transferId, guid, 10e6, 1);
        assertEq(_nav(), 10e6, "credited");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 10e6);

        _attest(10e6, 1); // anchored, no UnanchoredAttestation
        assertEq(_nav(), 10e6);
    }
}

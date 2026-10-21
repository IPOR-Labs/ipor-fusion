// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {ICrosschainExecutor, BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {Vm} from "forge-std/Vm.sol";

/// @title ExecutorAttestationTest
/// @notice P1 audit regression suite: NAV attestation metadata completeness and freshness. Verifies that
///         `proposeBalance`/`approveBalance` reject incomplete/forged/stale observation metadata, persist
///         and expose the full observation, and anchor settled-NAV freshness to the REMOTE observation
///         timestamp rather than the local approval time (CROSSCHAIN_AUDIT_FIX_PLAN §3).
contract ExecutorAttestationTest is CrosschainTestBase {
    event BalanceProposed(
        uint256 proposalId,
        uint256 chainId,
        uint256 settledSD,
        uint64 stateVersion,
        uint64 remoteBlock,
        uint64 remoteTimestamp,
        uint64 expiry,
        bytes32 trackedPositionSetHash
    );

    /// @dev Library event (IL-8472), emitted by the executor address.
    event ProposalInvalidated(uint256 chainId, uint256 proposalId, uint64 newEpoch);

    bytes32 internal constant PROPOSAL_INVALIDATED_TOPIC = keccak256("ProposalInvalidated(uint256,uint256,uint64)");

    function setUp() public {
        _baseSetUp();
    }

    // ---------------------------------------------------------------------
    // Helper: build a fully-parameterized observation
    // ---------------------------------------------------------------------

    function _obs(uint64 stateVersion_, uint64 remoteBlock_, uint64 remoteTimestamp_, uint64 expiry_)
        internal
        pure
        returns (BalanceObservation memory)
    {
        return BalanceObservation({
            chainId: REMOTE_CHAIN,
            settledBalance: 0,
            stateVersion: stateVersion_,
            remoteBlock: remoteBlock_,
            remoteTimestamp: remoteTimestamp_,
            expiry: expiry_,
            trackedPositionSetHash: bytes32(0)
        });
    }

    // ---------------------------------------------------------------------
    // Metadata completeness at propose
    // ---------------------------------------------------------------------

    function testShouldRejectZeroRemoteBlockOnPropose() public {
        _readyDispatcher();
        BalanceObservation memory o = _obs(0, 0, uint64(block.timestamp), uint64(block.timestamp + 30 minutes));
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.InvalidObservationMetadata.selector, REMOTE_CHAIN));
        executor.proposeBalance(o);
    }

    function testShouldRejectZeroRemoteTimestampOnPropose() public {
        _readyDispatcher();
        BalanceObservation memory o = _obs(0, 1, 0, uint64(block.timestamp + 30 minutes));
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.InvalidObservationMetadata.selector, REMOTE_CHAIN));
        executor.proposeBalance(o);
    }

    function testShouldRejectFutureRemoteTimestampOnPropose() public {
        _readyDispatcher();
        BalanceObservation memory o = _obs(0, 1, uint64(block.timestamp + 1), uint64(block.timestamp + 30 minutes));
        vm.prank(proposer);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.InvalidObservationMetadata.selector, REMOTE_CHAIN));
        executor.proposeBalance(o);
    }

    // ---------------------------------------------------------------------
    // Minimum meaningful approval window at propose (V2-02)
    // ---------------------------------------------------------------------

    function testShouldRejectProposalWithApprovalWindowBelowMinimum() public {
        _readyDispatcher();
        // expiry one second short of the minimum window: still in the future (so not `ProposalExpired`)
        // but leaves no meaningful time for the approver, which must be rejected at propose-time.
        uint64 tooShort = uint64(block.timestamp + CrosschainConstants.MIN_PROPOSAL_APPROVAL_WINDOW - 1);
        BalanceObservation memory o = _obs(0, 1, uint64(block.timestamp), tooShort);
        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.ProposalApprovalWindowTooShort.selector,
                REMOTE_CHAIN,
                CrosschainConstants.MIN_PROPOSAL_APPROVAL_WINDOW - 1,
                CrosschainConstants.MIN_PROPOSAL_APPROVAL_WINDOW
            )
        );
        executor.proposeBalance(o);
    }

    function testShouldAcceptProposalWithApprovalWindowAtMinimum() public {
        _readyDispatcher();
        // exactly the minimum window is accepted (boundary is inclusive).
        uint64 atMin = uint64(block.timestamp + CrosschainConstants.MIN_PROPOSAL_APPROVAL_WINDOW);
        BalanceObservation memory o = _obs(0, 1, uint64(block.timestamp), atMin);
        vm.prank(proposer);
        executor.proposeBalance(o);
        assertEq(executor.activeProposalId(REMOTE_CHAIN), executor.proposalCount(), "proposal accepted at boundary");
    }

    // ---------------------------------------------------------------------
    // Freshness re-check between propose and approve
    // ---------------------------------------------------------------------

    function testShouldRejectProposalThatBecomesStaleBeforeApprove() public {
        _readyDispatcher();
        _settle100(); // settled = 100e6, frontier = 2

        // Fresh at propose, expiry far enough out that staleness (not expiry) is the binding gate.
        BalanceObservation memory o = _obs(1, 7, uint64(block.timestamp), uint64(block.timestamp + 3 hours));
        o.settledBalance = 100e6;
        vm.prank(proposer);
        executor.proposeBalance(o);
        uint256 pid = executor.proposalCount();

        // Age past STALENESS_MAX but still before expiry: approval must revert as stale, not expired.
        vm.warp(block.timestamp + STALENESS_MAX + 1);
        vm.prank(approver);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ObservationStale.selector, REMOTE_CHAIN));
        executor.approveBalance(pid);
    }

    function testShouldRejectExpiredProposalAtApprove() public {
        _readyDispatcher();
        _settle100();

        BalanceObservation memory o = _obs(1, 7, uint64(block.timestamp), uint64(block.timestamp + 20 minutes));
        o.settledBalance = 100e6;
        vm.prank(proposer);
        executor.proposeBalance(o);
        uint256 pid = executor.proposalCount();

        // Past expiry but still within STALENESS_MAX (20min < 1h): expiry is the binding gate.
        vm.warp(block.timestamp + 20 minutes + 1);
        vm.prank(approver);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ProposalExpired.selector, pid));
        executor.approveBalance(pid);
    }

    // ---------------------------------------------------------------------
    // Freshness marker anchored to REMOTE observation timestamp
    // ---------------------------------------------------------------------

    function testShouldMarkSettledStaleRelativeToRemoteTimestampNotApproval() public {
        _readyDispatcher();
        _settle100(); // settled = 100e6, frontier = 2

        uint64 observedAt = uint64(block.timestamp - 30 minutes); // observed half a staleness-window ago
        BalanceObservation memory o = _obs(1, 9, observedAt, uint64(block.timestamp + 1 hours));
        o.settledBalance = 100e6;
        vm.prank(proposer);
        executor.proposeBalance(o);
        uint256 pid = executor.proposalCount();

        vm.prank(approver);
        executor.approveBalance(pid);
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), observedAt, "freshness marker = remote observed time");
        assertEq(executor.getBalance(), 100e6, "fresh NAV readable right after approval");

        // The window is measured from `observedAt`, so it expires 30 minutes sooner than if it had been
        // anchored to the approval time. At exactly observedAt + STALENESS_MAX it is still fresh...
        vm.warp(uint256(observedAt) + STALENESS_MAX);
        assertEq(executor.getBalance(), 100e6, "fresh at the staleness boundary (remote-anchored)");
        // ...and one second later it is stale, even though only ~30 minutes elapsed since approval.
        vm.warp(uint256(observedAt) + STALENESS_MAX + 1);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavSettledStale.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    // ---------------------------------------------------------------------
    // Metadata + position-set hash exposed through getter and event
    // ---------------------------------------------------------------------

    function testShouldExposeObservationMetadataThroughGetterAndEvent() public {
        _readyDispatcher();

        bytes32 setHash = keccak256("tracked-position-set");
        uint64 rBlock = 123456;
        uint64 rTs = uint64(block.timestamp - 5 minutes);
        uint64 exp = uint64(block.timestamp + 30 minutes);
        BalanceObservation memory o = BalanceObservation({
            chainId: REMOTE_CHAIN,
            settledBalance: 0,
            stateVersion: 0,
            remoteBlock: rBlock,
            remoteTimestamp: rTs,
            expiry: exp,
            trackedPositionSetHash: setHash
        });

        vm.expectEmit(false, false, false, true, address(executor));
        emit BalanceProposed(1, REMOTE_CHAIN, 0, 0, rBlock, rTs, exp, setHash);
        vm.prank(proposer);
        executor.proposeBalance(o);

        (
            uint256 chainId,,
            uint64 stateVersion,
            uint64 remoteBlock,
            uint64 remoteTimestamp,
            uint64 expiry,
            bytes32 trackedPositionSetHash,,
            uint8 status
        ) = executor.proposals(1);
        assertEq(chainId, REMOTE_CHAIN, "chainId persisted");
        assertEq(stateVersion, 0, "stateVersion persisted");
        assertEq(remoteBlock, rBlock, "remoteBlock persisted (was previously dropped)");
        assertEq(remoteTimestamp, rTs, "remoteTimestamp persisted");
        assertEq(expiry, exp, "expiry persisted");
        assertEq(trackedPositionSetHash, setHash, "position-set hash persisted for off-chain verification");
        assertEq(status, 1, "status PENDING");
    }

    // ---------------------------------------------------------------------
    // Proposal invalidation after an accounting mutation stays intact
    // ---------------------------------------------------------------------

    function testShouldInvalidateProposalAfterAccountingMutation() public {
        _readyDispatcher();
        _settle100(); // settled = 100e6, frontier = 2

        BalanceObservation memory o = _obs(1, 7, uint64(block.timestamp), uint64(block.timestamp + 30 minutes));
        o.settledBalance = 100e6;
        vm.prank(proposer);
        executor.proposeBalance(o);
        uint256 pid = executor.proposalCount();
        assertEq(executor.activeProposalId(REMOTE_CHAIN), pid, "proposal active");

        // A value landing (versioned TRANSFER_SETTLED) bumps the accounting epoch and clears the active proposal.
        // A bare outbound send does not (IL-8622, see StargateProposalSurvivesOutboundTest).
        (bytes32 transferId, bytes32 guid,) = _sendAsset(10e6, 0);
        _deliverTransferSettled(transferId, guid, 10e6, 2);
        assertEq(executor.activeProposalId(REMOTE_CHAIN), 0, "proposal invalidated by accounting mutation");
        vm.prank(approver);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ProposalNotActive.selector, pid));
        executor.approveBalance(pid);
    }

    // ---------------------------------------------------------------------
    // IL-8472 (B-12): a voided active proposal is announced and marked SUPERSEDED
    // ---------------------------------------------------------------------

    function _proposeSettled100() internal returns (uint256 pid) {
        BalanceObservation memory o = _obs(1, 7, uint64(block.timestamp), uint64(block.timestamp + 30 minutes));
        o.settledBalance = 100e6;
        vm.prank(proposer);
        executor.proposeBalance(o);
        pid = executor.proposalCount();
    }

    function _proposalStatus(uint256 pid_) internal view returns (uint8 status) {
        (,,,,,,,, status) = executor.proposals(pid_);
    }

    function _countInvalidated(Vm.Log[] memory logs_) internal view returns (uint256 count) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(executor) && logs_[i].topics[0] == PROPOSAL_INVALIDATED_TOPIC) ++count;
        }
    }

    function testShouldEmitProposalInvalidatedAndMarkSupersededOnSettle() public {
        _readyDispatcher();
        _settle100();
        (bytes32 transferId, bytes32 guid,) = _sendAsset(10e6, 0);
        uint256 pid = _proposeSettled100();
        assertEq(_proposalStatus(pid), 1, "PENDING before the bump");
        uint64 newEpoch = executor.accountingEpoch(REMOTE_CHAIN) + 1;

        vm.recordLogs();
        _deliverTransferSettled(transferId, guid, 10e6, 2);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countInvalidated(logs), 1, "exactly one ProposalInvalidated");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(executor) && logs[i].topics[0] == PROPOSAL_INVALIDATED_TOPIC) {
                (uint256 chainId, uint256 invalidatedId, uint64 epoch) =
                    abi.decode(logs[i].data, (uint256, uint256, uint64));
                assertEq(chainId, REMOTE_CHAIN, "chain");
                assertEq(invalidatedId, pid, "proposal id");
                assertEq(epoch, newEpoch, "new epoch");
            }
        }

        assertEq(_proposalStatus(pid), 4, "status SUPERSEDED");
        assertEq(executor.activeProposalId(REMOTE_CHAIN), 0, "no active proposal");
        vm.prank(approver);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ProposalNotActive.selector, pid));
        executor.approveBalance(pid);
        vm.prank(approver);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ProposalNotActive.selector, pid));
        executor.rejectAndBlockProposal(pid);
    }

    function testShouldNotEmitProposalInvalidatedOnEpochBumpWithoutActiveProposal() public {
        _readyDispatcher();
        _settle100();
        (bytes32 transferId, bytes32 guid,) = _sendAsset(10e6, 0);
        assertEq(executor.activeProposalId(REMOTE_CHAIN), 0, "no active proposal");
        uint64 epochBefore = executor.accountingEpoch(REMOTE_CHAIN);

        vm.recordLogs();
        _deliverTransferSettled(transferId, guid, 10e6, 2);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertGt(executor.accountingEpoch(REMOTE_CHAIN), epochBefore, "epoch bumped");
        assertEq(_countInvalidated(logs), 0, "nothing to invalidate, nothing emitted");
    }

    function testShouldSupersedeThePreviousActiveProposalOnNewPropose() public {
        _readyDispatcher();
        _settle100();
        uint256 first = _proposeSettled100();
        uint64 epoch = executor.accountingEpoch(REMOTE_CHAIN);

        vm.expectEmit(false, false, false, true, address(executor));
        emit ProposalInvalidated(REMOTE_CHAIN, first, epoch);
        uint256 second = _proposeSettled100();

        assertEq(second, first + 1, "new id");
        assertEq(_proposalStatus(first), 4, "old proposal SUPERSEDED");
        assertEq(_proposalStatus(second), 1, "new proposal PENDING");
        assertEq(executor.activeProposalId(REMOTE_CHAIN), second, "new proposal active");
        assertEq(executor.accountingEpoch(REMOTE_CHAIN), epoch, "propose does not bump the epoch");
        vm.prank(approver);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ProposalNotActive.selector, first));
        executor.approveBalance(first);
    }

    function testShouldNotEmitProposalInvalidatedOnFirstPropose() public {
        _readyDispatcher();
        _settle100();
        vm.recordLogs();
        _proposeSettled100();
        assertEq(_countInvalidated(vm.getRecordedLogs()), 0, "no previous proposal, nothing emitted");
    }
}

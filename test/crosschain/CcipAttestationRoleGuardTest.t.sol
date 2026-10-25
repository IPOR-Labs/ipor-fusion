// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CcipExecutorFixture} from "./CcipExecutorFixture.sol";
import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";

/// @title CcipAttestationRoleGuardTest
/// @notice IL-9138 (ccip-exec C-005): `OnlyBalanceApprover` and `OnlyBalanceProposer` are asserted nowhere in the
///         CCIP suites. Pins the caller guards of `proposeBalance`, `approveBalance` and `rejectBalanceAndBlock`:
///         a stranger and the other attestation role are refused by selector, the proposal stays PENDING and the
///         chain is not blocked.
contract CcipAttestationRoleGuardTest is CcipExecutorFixture {
    address internal constant STRANGER = address(0xBAD);

    uint256 internal proposalId;

    function setUp() public {
        _fixtureSetUp();
        _bridge(100e18);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        // The test contract is BALANCE_PROPOSER; leave one PENDING proposal for the approver-only calls.
        proposalId = _propose(100e18);
    }

    function _assertProposalUntouched() internal view {
        assertEq(executor.activeProposalId(REMOTE_CHAIN), proposalId, "proposal still the active one");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "chain not blocked");
        assertEq(executor.lastApprovedObservedAt(REMOTE_CHAIN), 0, "nothing approved");
    }

    function _assertStillApprovable() internal {
        vm.prank(APPROVER);
        executor.approveBalance(proposalId);
        assertGt(executor.lastApprovedObservedAt(REMOTE_CHAIN), 0, "proposal was still PENDING and approvable");
    }

    // ---- approveBalance ----

    function testShouldRejectApproveBalanceFromStranger() public {
        vm.prank(STRANGER);
        vm.expectRevert(CcipCrosschainExecutor.OnlyBalanceApprover.selector);
        executor.approveBalance(proposalId);
        _assertProposalUntouched();
        _assertStillApprovable();
    }

    function testShouldRejectApproveBalanceFromProposer() public {
        // address(this) is BALANCE_PROPOSER: proposing rights do not grant approval.
        vm.expectRevert(CcipCrosschainExecutor.OnlyBalanceApprover.selector);
        executor.approveBalance(proposalId);
        _assertProposalUntouched();
        _assertStillApprovable();
    }

    // ---- rejectBalanceAndBlock ----

    function testShouldRejectRejectBalanceAndBlockFromStranger() public {
        vm.prank(STRANGER);
        vm.expectRevert(CcipCrosschainExecutor.OnlyBalanceApprover.selector);
        executor.rejectBalanceAndBlock(proposalId);
        _assertProposalUntouched();
        _assertStillApprovable();
    }

    function testShouldRejectRejectBalanceAndBlockFromProposer() public {
        vm.expectRevert(CcipCrosschainExecutor.OnlyBalanceApprover.selector);
        executor.rejectBalanceAndBlock(proposalId);
        _assertProposalUntouched();
        _assertStillApprovable();
    }

    // ---- proposeBalance ----

    function testShouldRejectProposeBalanceFromStranger() public {
        _assertProposeRefused(STRANGER);
    }

    function testShouldRejectProposeBalanceFromApprover() public {
        // The approver role is distinct from the proposer role.
        _assertProposeRefused(APPROVER);
    }

    function _assertProposeRefused(address caller_) internal {
        vm.warp(block.timestamp + 1);
        uint64 version = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        bytes32 positionsHash = dispatcher.trackedPositionSetHash();
        uint64 observedAt = uint64(block.timestamp);
        uint64 expiry = uint64(block.timestamp + 1 days);
        vm.prank(caller_);
        vm.expectRevert(CcipCrosschainExecutor.OnlyBalanceProposer.selector);
        executor.proposeBalance(REMOTE_CHAIN, 100e18, version, uint64(block.number), observedAt, expiry, positionsHash);
        _assertProposalUntouched();
    }
}

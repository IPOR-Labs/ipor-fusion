// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";

/// @title StargateProposalSurvivesOutboundTest
/// @notice IL-8622 (Ackee TP-M-44): an outbound send (or a rejected recall) moves no attested value, so it must not
///         void the pending balance proposal. Before the fix `recordOutbound` / `_onReturnRejected` bumped the
///         accounting epoch, so the ALPHA role could land a one-unit send between `proposeBalance` and
///         `approveBalance` and keep the NAV from ever being refreshed (`NavSettledStale`). A versioned
///         TRANSFER_SETTLED still voids the proposal.
contract StargateProposalSurvivesOutboundTest is CrosschainTestBase {
    function setUp() public {
        _baseSetUp();
        _readyAndFundIdle40(); // idle 40e6, settled 60e6, frontier = 2
    }

    function _propose(uint256 settledLD_, uint64 version_) internal returns (uint256 pid) {
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
        pid = executor.proposalCount();
    }

    function _approve(uint256 pid_) internal {
        vm.prank(approver);
        executor.approveBalance(pid_);
    }

    function testShouldKeepPendingProposalApprovableAfterOutboundSend() public {
        uint256 pid = _propose(60e6, 2);
        uint64 epochBefore = executor.accountingEpoch(REMOTE_CHAIN);

        (bytes32 transferId, bytes32 guid,) = _sendAsset(10e6, 0);

        assertEq(executor.accountingEpoch(REMOTE_CHAIN), epochBefore, "send does not bump the epoch");
        assertEq(executor.activeProposalId(REMOTE_CHAIN), pid, "proposal still active");
        _approve(pid);
        // idle 40 + settled 60 + outbound in flight 10
        assertEq(executor.getBalance(), 110e6, "NAV = idle + settled + outbound");

        // the settle moves the 10 from outbound to settled: approving after a send changed nothing end to end
        _deliverTransferSettled(transferId, guid, 10e6, 3);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 70e6, "settled = 60 + 10");
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0, "outbound settled");
        assertEq(executor.getBalance(), 110e6, "NAV unchanged by the settle");
    }

    function testShouldKeepPendingProposalApprovableAfterRejectedReturn() public {
        (bytes32 requestId,,) = _requestAssets(20e6, 0);
        uint256 pid = _propose(60e6, 2);
        uint64 epochBefore = executor.accountingEpoch(REMOTE_CHAIN);

        _deliverReturnRejected(requestId); // NO_TRACKED_IDLE

        assertEq(executor.accountingEpoch(REMOTE_CHAIN), epochBefore, "rejection does not bump the epoch");
        assertEq(executor.activeProposalId(REMOTE_CHAIN), pid, "proposal still active");
        _approve(pid);
        assertEq(executor.getBalance(), 100e6, "NAV = idle 40 + settled 60");
    }

    function testShouldVoidPendingProposalWhenOutboundSettles() public {
        (bytes32 transferId, bytes32 guid,) = _sendAsset(10e6, 0);
        uint256 pid = _propose(60e6, 2);
        uint64 epochBefore = executor.accountingEpoch(REMOTE_CHAIN);

        _deliverTransferSettled(transferId, guid, 10e6, 3);

        assertGt(executor.accountingEpoch(REMOTE_CHAIN), epochBefore, "settle bumps the epoch");
        assertEq(executor.activeProposalId(REMOTE_CHAIN), 0, "proposal voided");
        vm.prank(approver);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ProposalNotActive.selector, pid));
        executor.approveBalance(pid);
    }

    function testShouldNotLetRepeatedOneUnitSendsCensorApproval() public {
        uint256 pid = _propose(60e6, 2);

        for (uint256 i; i < 10; ++i) {
            _sendAsset(1, 0);
        }

        assertEq(executor.activeProposalId(REMOTE_CHAIN), pid, "proposal still active after ten sends");
        _approve(pid);
        assertEq(executor.getBalance(), 100e6 + 10, "NAV includes the ten in-flight units");
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CcipExecutorFixture} from "./CcipExecutorFixture.sol";
import {CcipExecutorAttestationLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorAttestationLib.sol";
import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";

/// @title CcipProposalWindowTest
/// @notice IL-9023: the CCIP executor refuses a proposal whose approval window is shorter than
///         `MIN_PROPOSAL_APPROVAL_WINDOW` with the descriptive `ProposalApprovalWindowTooShort` (the Stargate
///         executor's error) instead of the generic `ProposalExpired(0)`, which stays reserved for an expiry
///         that is not in the future.
contract CcipProposalWindowTest is CcipExecutorFixture {
    uint256 internal constant BAL = 100e18;
    uint256 internal constant MIN_WINDOW = CrosschainConstants.MIN_PROPOSAL_APPROVAL_WINDOW;

    function setUp() public {
        _fixtureSetUp();
        _bridge(BAL);
        vm.warp(block.timestamp + 1 hours);
    }

    function _proposeWithExpiry(uint64 expiry_) internal returns (uint256) {
        return _proposeExpecting(expiry_, "");
    }

    /// @dev Reads the arguments first: `vm.expectRevert` applies to the next external call, which must be
    ///      `proposeBalance` and not one of the view reads feeding it.
    function _proposeExpecting(uint64 expiry_, bytes memory revertData_) internal returns (uint256) {
        uint64 version = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        bytes32 positionSetHash = dispatcher.trackedPositionSetHash();
        if (revertData_.length != 0) vm.expectRevert(revertData_);
        return
            executor.proposeBalance(REMOTE_CHAIN, BAL, version, 1, uint64(block.timestamp), expiry_, positionSetHash);
    }

    function testShouldAcceptWindowOfExactlyTheMinimum() public {
        uint256 id = _proposeWithExpiry(uint64(block.timestamp + MIN_WINDOW));
        assertTrue(id != 0, "boundary window creates a proposal");
        vm.prank(APPROVER);
        executor.approveBalance(id);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), BAL, "boundary proposal is approvable");
    }

    function testShouldRejectWindowOneSecondBelowTheMinimum() public {
        _proposeExpecting(
            uint64(block.timestamp + MIN_WINDOW - 1),
            abi.encodeWithSelector(
                CrosschainErrors.ProposalApprovalWindowTooShort.selector,
                REMOTE_CHAIN,
                MIN_WINDOW - 1,
                MIN_WINDOW
            )
        );
    }

    function testShouldReportShortWindowWithItsActualLength() public {
        _proposeExpecting(
            uint64(block.timestamp + 1),
            abi.encodeWithSelector(
                CrosschainErrors.ProposalApprovalWindowTooShort.selector,
                REMOTE_CHAIN,
                1,
                MIN_WINDOW
            )
        );
    }

    function testShouldKeepProposalExpiredZeroForExpiryNotInTheFuture() public {
        bytes memory expired = abi.encodeWithSelector(CcipExecutorAttestationLib.ProposalExpired.selector, uint256(0));
        _proposeExpecting(uint64(block.timestamp), expired);
        _proposeExpecting(uint64(block.timestamp - 1), expired);
    }

    function testShouldRejectApprovalAfterExpiry() public {
        uint64 expiry = uint64(block.timestamp + MIN_WINDOW);
        uint256 id = _proposeWithExpiry(expiry);
        vm.warp(uint256(expiry) + 1);
        vm.prank(APPROVER);
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorAttestationLib.ProposalExpired.selector, id));
        executor.approveBalance(id);
    }
}

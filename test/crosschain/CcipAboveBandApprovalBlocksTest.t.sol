// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {stdStorage, StdStorage} from "forge-std/Test.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipExecutorTransferLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorTransferLib.sol";
import {CcipChainRescue} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CcipExecutorFixture} from "./CcipExecutorFixture.sol";

/// @title CcipAboveBandApprovalBlocksTest
/// @notice IL-9720 (3sigma #26, part 2), CCIP: the attester pair approves a TRUE value above the anchor band. The approval
///         used to revert `AttestationOutsideAnchorBand`, which pinned NAV to the stale `settled` (the edge of the band)
///         while the proposal stayed pending. It now writes nothing, rejects the proposal and blocks the chain, the same
///         outcome as `rejectBalanceAndBlock`; an already blocked chain, a value below the band and the zero-baseline
///         branch keep the revert. Default configuration (band 2_000): the file compiles and runs on the base commit,
///         where the first two tests fail.
contract CcipAboveBandApprovalBlocksTest is CcipExecutorFixture {
    using stdStorage for StdStorage;

    /// @dev `AttestationOutsideAnchorBand(uint256,uint256,uint256,uint256)`, derived from the signature on purpose.
    bytes4 internal constant OUTSIDE_BAND =
        bytes4(keccak256("AttestationOutsideAnchorBand(uint256,uint256,uint256,uint256)"));
    bytes4 internal constant BIG_CHANGE = bytes4(keccak256("BigChangeExceeded(uint256,uint256,uint256)"));

    function setUp() public {
        _fixtureSetUp();
    }

    function _tryApprove(uint256 balance_) internal returns (bool ok, bytes memory reason, uint256 proposalId) {
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        proposalId = _propose(balance_);
        vm.prank(APPROVER);
        try executor.approveBalance(proposalId) {
            ok = true;
        } catch (bytes memory data) {
            reason = data;
        }
    }

    function testShouldBlockTheChainWhenTheApprovedValueIsAboveTheBand() public {
        _bridge(100e18); // settled = anchor = 100
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(120e18); // the upper edge of the band passes
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 120e18);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 proposalId = _propose(120e18 + 1);
        vm.expectEmit(address(executor));
        emit CcipCrosschainExecutor.BalanceRejectedAndBlocked(proposalId, REMOTE_CHAIN);
        vm.prank(APPROVER);
        executor.approveBalance(proposalId);

        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "the chain is blocked");
        assertEq(executor.activeProposalId(REMOTE_CHAIN), 0, "the proposal is closed");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 120e18, "settled is unchanged: nothing was written");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 100e18, "the anchor is unchanged");
        vm.expectRevert(abi.encodeWithSelector(CcipExecutorTransferLib.ChainBlocked.selector, REMOTE_CHAIN));
        executor.getBalance();
    }

    function testShouldBlockTheChainEvenWhenTheValueIsFarBeyondTheRelativeStep() public {
        _bridge(100e18);
        (bool ok, , ) = _tryApprove(200e18); // +100% from the approved 100: the band is checked first
        assertTrue(ok, "the approval does not revert");
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "the chain is blocked");
        assertEq(executor.activeProposalId(REMOTE_CHAIN), 0, "the proposal is closed");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18);
    }

    function testShouldKeepTheRevertWhenTheChainIsAlreadyBlocked() public {
        _bridge(100e18);
        (bool ok, , ) = _tryApprove(200e18);
        assertTrue(ok);
        assertTrue(executor.chainBlocked(REMOTE_CHAIN));

        bytes memory reason;
        (ok, reason, ) = _tryApprove(200e18);
        assertFalse(ok, "an already blocked chain keeps the revert");
        assertEq(reason, abi.encodeWithSelector(OUTSIDE_BAND, REMOTE_CHAIN, 100e18, 200e18, 2_000));
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "still blocked");
    }

    function testShouldNotClearTheFrontierRepairLatchWhenTheBlockedChainRefusesAValueAboveTheBand() public {
        _bridge(100e18);
        uint64 newVersion = executor.lastRemoteStateVersion(REMOTE_CHAIN) + 5;
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.ADVANCE_FRONTIER, REMOTE_CHAIN, newVersion);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.ADVANCE_FRONTIER, REMOTE_CHAIN, newVersion);
        assertTrue(executor.frontierRepairPending(REMOTE_CHAIN), "repair armed");
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "the repair blocks the chain");

        (bool ok, bytes memory reason, ) = _tryApprove(130e18);
        assertFalse(ok, "the revert stays");
        assertEq(reason, abi.encodeWithSelector(OUTSIDE_BAND, REMOTE_CHAIN, 100e18, 130e18, 2_000));
        assertTrue(executor.frontierRepairPending(REMOTE_CHAIN), "the latch is not cleared");
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "still blocked");
    }

    function testShouldStillRevertBelowTheBand() public {
        _bridge(100e18);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(80e18); // the lower edge
        (bool ok, bytes memory reason, ) = _tryApprove(80e18 - 1); // below the band, inside the relative step
        assertFalse(ok, "below the band is still refused by a revert");
        assertEq(reason, abi.encodeWithSelector(OUTSIDE_BAND, REMOTE_CHAIN, 100e18, 80e18 - 1, 2_000));
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "the chain is not blocked");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 80e18);
    }

    function testShouldStillRevertARelativeStepInsideTheBand() public {
        _bridge(100e18);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(80e18);
        (bool ok, bytes memory reason, ) = _tryApprove(96e18 + 1); // inside the band, 20% + 1 above the approved 80
        assertFalse(ok);
        assertEq(reason, abi.encodeWithSelector(BIG_CHANGE, 80e18, 96e18 + 1, 2_000));
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "inside the band nothing blocks the chain");
    }

    /// @dev Zero baseline (a full recall left a residual anchor): the branch is unchanged, the value above the band still
    ///      reverts and the chain is not blocked.
    function testShouldKeepTheRevertOnTheZeroBaselineBranch() public {
        _bridge(100e18);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        _attest(100e18);
        token.mint(address(dispatcher), 10e18); // yield realised on the dispatcher
        stdstore.target(address(dispatcher)).sig("trackedIdle()").checked_write(dispatcher.trackedIdle() + 10e18);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 100e18, 0, 0, address(0), 500_000);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "bucket emptied");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 10e18, "residual anchor");

        (bool ok, bytes memory reason, ) = _tryApprove(12e18 + 1);
        assertFalse(ok, "the zero-baseline branch still reverts");
        assertEq(reason, abi.encodeWithSelector(OUTSIDE_BAND, REMOTE_CHAIN, 10e18, 12e18 + 1, 2_000));
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "the chain is not blocked");
    }
}

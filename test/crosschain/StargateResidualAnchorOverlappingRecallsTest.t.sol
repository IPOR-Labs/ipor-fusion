// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {StargateExecutorAccountingLib} from "../../contracts/crosschain/stargate/lib/StargateExecutorAccountingLib.sol";
import {StargateExecutorState, ReturnRecord} from "../../contracts/crosschain/stargate/lib/StargateExecutorState.sol";

/// @title StargateResidualAnchorOverlappingRecallsTest
/// @notice IL-9163 (Codex stargate-exec C-005). Two overlapping recalls: A is cancelled after
///         `TRANSFER_STALENESS_MAX`, B is requested against the unchanged `settled`, and the dispatcher (which never
///         learned of the cancel) serves A first and B second. A's metadata empties `settled` and keeps A's
///         residual as the anchor; B's metadata has nothing to debit. Before the fix the anchor stayed at A's
///         residual, so the attester pair could approve a phantom value inside the band around it. The anchor now
///         follows the balance the dispatcher reported with B.
contract StargateResidualAnchorOverlappingRecallsTest is CrosschainTestBase {
    function setUp() public {
        _baseSetUp();
        _readyDispatcher();
    }

    function _observation(uint256 settledLD_, uint64 stateVersion_) internal view returns (BalanceObservation memory) {
        return
            BalanceObservation({
                chainId: REMOTE_CHAIN,
                settledBalance: settledLD_,
                stateVersion: stateVersion_,
                remoteBlock: 1,
                remoteTimestamp: uint64(block.timestamp),
                expiry: uint64(block.timestamp + 30 minutes),
                trackedPositionSetHash: bytes32(0)
            });
    }

    function _propose(uint256 settledLD_, uint64 stateVersion_) internal returns (uint256 proposalId) {
        vm.prank(proposer);
        executor.proposeBalance(_observation(settledLD_, stateVersion_));
        return executor.proposalCount();
    }

    /// @dev settled = anchor = 100e6; A (100e6) cancelled after the staleness bound; B (8e6) requested against the
    ///      unchanged settled; the dispatcher then serves A (sent 100e6, remote 10e6) and B (sent 8e6, remote
    ///      `remoteAfterB_`), metadata and compose in version order. Returns the last delivered state version.
    function _overlappingRecalls(uint256 remoteAfterB_) internal returns (uint64 lastVersion) {
        _settle100(); // settled = anchor = 100e6, frontier 1
        (bytes32 idA, , ) = _requestAssets(100e6, 0);
        vm.warp(block.timestamp + TRANSFER_STALENESS_MAX + 1);
        vm.prank(makeAddr("anyone"));
        executor.cancelStaleReturnRequest(REMOTE_CHAIN);
        (bytes32 idB, , uint256 maxAccountedB) = _requestAssets(8e6, 0);
        assertEq(maxAccountedB, 8e6, "B is bound against the unchanged settled bucket");

        bytes32 guidB = keccak256("return-guid-B");

        returnStartedRemoteBalanceSD = 10e6;
        _deliverReturnStarted(idA, RGUID, 100e6, 100e6, 2);
        usdc.mint(address(executor), 100e6);
        _deliverReturnCompose(idA, RGUID, 100e6);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "A empties the bucket");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 10e6, "A's residual is kept as the anchor");

        returnStartedRemoteBalanceSD = remoteAfterB_;
        _deliverReturnStarted(idB, guidB, 8e6, 8e6, 3);
        usdc.mint(address(executor), 8e6);
        _deliverReturnCompose(idB, guidB, 8e6);
        return 3;
    }

    function testShouldFollowLaterRecallBalanceAfterOverlappingRecalls() public {
        _overlappingRecalls(2e6);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "settled stays zero");
        assertEq(
            executor.attestationAnchorPrincipal(REMOTE_CHAIN),
            2e6,
            "anchor follows B's authenticated remote balance"
        );
    }

    /// @dev Codex #1: proposals above the band are made while `settled` is still zero, before any real attestation,
    ///      because afterwards the 10% relative limiter would reject a larger value before the band is reached.
    function testShouldRejectApprovalJustAboveTheBandOfTheLaterRecallBalance() public {
        _overlappingRecalls(2e6);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);

        uint256 pid = _propose(2_400_001, 3); // band is 20%: 2e6 * 1.2 = 2.4e6
        vm.prank(approver);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.AttestationOutsideAnchorBand.selector,
                REMOTE_CHAIN,
                2e6,
                2_400_001,
                2_000
            )
        );
        executor.approveBalance(pid);
    }

    /// @dev Before the fix the stale anchor (10e6) approved 12e6 from the zero baseline: phantom NAV against a true 2e6.
    function testShouldRejectPhantomValueThatTheStaleAnchorWouldHaveApproved() public {
        _overlappingRecalls(2e6);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);

        uint256 pid = _propose(12e6, 3);
        vm.prank(approver);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.AttestationOutsideAnchorBand.selector,
                REMOTE_CHAIN,
                2e6,
                12e6,
                2_000
            )
        );
        executor.approveBalance(pid);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "no phantom value was written");
    }

    function testShouldApproveTheTruthfulLeftoverAfterOverlappingRecalls() public {
        _overlappingRecalls(2e6);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);

        uint256 pid = _propose(2e6, 3);
        vm.prank(approver);
        executor.approveBalance(pid);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 2e6, "the real leftover is priced");
    }

    function testShouldZeroAnchorWhenLaterRecallDrainsTheDispatcher() public {
        _overlappingRecalls(0);

        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 0, "B drained the dispatcher: anchor zero");
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _propose(12e6, 3);
        vm.prank(approver);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.UnanchoredAttestation.selector, REMOTE_CHAIN, 12e6));
        executor.approveBalance(pid);

        // zero to zero stays approvable
        pid = _propose(0, 3);
        vm.prank(approver);
        executor.approveBalance(pid);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0);
    }
}

/// @dev Thin wrapper so the library's internal `_applyReturnDebit` can be driven directly with chosen state.
contract StargateReturnDebitHarness {
    StargateExecutorState internal s;
    mapping(bytes32 => ReturnRecord) internal recs;

    uint256 internal constant CHAIN = 1;
    bytes32 internal constant ID = bytes32(uint256(1));

    function seed(uint256 settled_, uint256 anchor_, uint256 maxAccounted_) external {
        s.settledRemoteBalance[CHAIN] = settled_;
        s.anchorPrincipal[CHAIN] = anchor_;
        recs[ID].maxAccountedSD = maxAccounted_;
    }

    function apply_(uint256 amountSentSD_, uint256 remoteBalanceSD_) external returns (uint256) {
        return StargateExecutorAccountingLib._applyReturnDebit(s, CHAIN, ID, recs[ID], amountSentSD_, remoteBalanceSD_);
    }

    function settled() external view returns (uint256) {
        return s.settledRemoteBalance[CHAIN];
    }

    function anchor() external view returns (uint256) {
        return s.anchorPrincipal[CHAIN];
    }
}

/// @title StargateResidualAnchorAtZeroSettledBoundaryTest
/// @notice IL-9163 boundaries of the `settled == 0 && amountSentSD_ != 0` rule on the library itself.
contract StargateResidualAnchorAtZeroSettledBoundaryTest is CrosschainTestBase {
    StargateReturnDebitHarness internal h;

    event AttestationAnchorUpdated(uint256 chainId, uint256 anchorPrincipal);

    function setUp() public {
        h = new StargateReturnDebitHarness();
    }

    function testShouldLowerAnchorToRemoteBalanceAndEmit() public {
        h.seed(0, 10e6, 8e6);
        vm.expectEmit(address(h));
        emit AttestationAnchorUpdated(1, 2e6);
        assertEq(h.apply_(8e6, 2e6), 0, "nothing to debit");
        assertEq(h.anchor(), 2e6);
    }

    function testShouldZeroAnchorAtOrBelowDust() public {
        h.seed(0, 10e6, 8e6);
        h.apply_(8e6, CrosschainConstants.ATTESTATION_ZERO_DUST_SD);
        assertEq(h.anchor(), 0, "dust is not an anchor");
    }

    function testShouldKeepAnchorJustAboveDust() public {
        h.seed(0, 10e6, 8e6);
        h.apply_(8e6, CrosschainConstants.ATTESTATION_ZERO_DUST_SD + 1);
        assertEq(h.anchor(), CrosschainConstants.ATTESTATION_ZERO_DUST_SD + 1);
    }

    function testShouldNeverRaiseTheAnchor() public {
        h.seed(0, 10e6, 8e6);
        h.apply_(8e6, 50e6); // inflated report
        assertEq(h.anchor(), 10e6, "capped at the current anchor");
    }

    function testShouldLeaveAnchorUntouchedWhenNothingWasSent() public {
        h.seed(0, 10e6, 8e6);
        h.apply_(0, 2e6);
        assertEq(h.anchor(), 10e6);
    }

    function testShouldNotTouchTheNonZeroSettledPath() public {
        // settled 100e6, anchor 100e6, debit 8e6 pro rata: anchor 92e6 (no residual involved)
        h.seed(100e6, 100e6, 8e6);
        assertEq(h.apply_(8e6, 2e6), 8e6);
        assertEq(h.settled(), 92e6);
        assertEq(h.anchor(), 92e6);
    }
}

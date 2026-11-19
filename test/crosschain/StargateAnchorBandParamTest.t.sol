// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";

import {StargateBandFixtureBase} from "./StargateLeveragedLegBandRegressionTest.t.sol";
import {StargateExecutorAccountingLib} from "../../contracts/crosschain/stargate/lib/StargateExecutorAccountingLib.sol";
import {StargateExecutorState, ReturnRecord} from "../../contracts/crosschain/stargate/lib/StargateExecutorState.sol";

/// @title StargateAnchorBandParamTest
/// @notice IL-9720: the geometry of the anchor band for a per-executor band on the Stargate executor, with exact numbers at
///         5_000, 10_000 and 50_000 bps: the upper and lower edge of `approve` (ordinary branch), the zero-baseline branch
///         on a residual anchor, the credit floor, and the fourth argument of `AttestationOutsideAnchorBand`.
///         `bigChangeBps` is 2_000 throughout, so the walk to an edge is made of ordinary steps of at most 20%.
contract StargateAnchorBandParamTest is StargateBandFixtureBase {
    using stdStorage for StdStorage;

    uint256 internal constant ANCHOR = 100e6;
    bytes32 internal constant RGUID_ = keccak256("band-return-guid");

    function _upEdge(uint256 bandBps_) internal {
        _setUpBand(2_000, bandBps_);
        _settle(ANCHOR);
        uint256 edge = (ANCHOR * (10_000 + bandBps_)) / 10_000;
        uint256 cur = ANCHOR;
        while ((cur * 12) / 10 < edge) {
            cur = (cur * 12) / 10;
            _attest(cur, 1);
        }
        uint256 snap = vm.snapshotState();
        (bool ok, bytes memory reason) = _tryAttest(edge + 1, 1);
        assertFalse(ok, "one unit above the edge is refused");
        assertEq(
            reason,
            abi.encodeWithSelector(OUTSIDE_BAND, REMOTE_CHAIN, ANCHOR, edge + 1, bandBps_),
            "the band, with the executor's band as fourth argument"
        );
        vm.revertToState(snap);
        _attest(edge, 1);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), edge, "the edge itself passes");
    }

    function _downEdge(uint256 bandBps_) internal {
        _setUpBand(2_000, bandBps_);
        _settle(ANCHOR);
        if (bandBps_ >= 10_000) {
            uint256 low = ANCHOR;
            for (uint256 i; i < 12; ++i) {
                low = (low * 8 + 9) / 10; // rounded up: never a step larger than 20%
                _attest(low, 1);
            }
            assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), low, "no lower edge above zero at b >= 1");
            return;
        }
        uint256 edge = (ANCHOR * (10_000 - bandBps_)) / 10_000;
        uint256 cur = ANCHOR;
        while ((cur * 8) / 10 > edge) {
            cur = (cur * 8) / 10;
            _attest(cur, 1);
        }
        uint256 snap = vm.snapshotState();
        (bool ok, bytes memory reason) = _tryAttest(edge - 1, 1);
        assertFalse(ok, "one unit below the edge is refused");
        assertEq(reason, abi.encodeWithSelector(OUTSIDE_BAND, REMOTE_CHAIN, ANCHOR, edge - 1, bandBps_));
        vm.revertToState(snap);
        _attest(edge, 1);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), edge, "the lower edge passes");
    }

    /// @dev settle 100, attest `100 - loss_`, a full recall of the attested amount in which the dispatcher reports
    ///      `residual_` still held (net principal = loss_), version 2 after the recall.
    function _fullRecallLeavingResidual(uint256 loss_, uint256 residual_) internal {
        _settle(ANCHOR);
        _attest(ANCHOR - loss_, 1);
        (bytes32 requestId, , ) = _requestAssets(ANCHOR - loss_, 0);
        returnStartedRemoteBalanceSD = residual_;
        _deliverReturnStarted(requestId, RGUID_, ANCHOR - loss_, ANCHOR - loss_, 2);
        usdc.mint(address(executor), ANCHOR - loss_);
        _deliverReturnCompose(requestId, RGUID_, ANCHOR - loss_);
    }

    function _zeroBaseline(uint256 bandBps_) internal {
        _setUpBand(2_000, bandBps_);
        _fullRecallLeavingResidual(0, 10e6);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "bucket emptied");
        uint256 residual = executor.attestationAnchorPrincipal(REMOTE_CHAIN);
        assertEq(residual, 10e6, "the residual stays as the anchor");
        uint256 edge = (residual * (10_000 + bandBps_)) / 10_000;
        uint256 snap = vm.snapshotState();
        (bool ok, bytes memory reason) = _tryAttest(edge + 1, 2);
        assertFalse(ok, "one unit above the zero-baseline edge is refused");
        assertEq(reason, abi.encodeWithSelector(OUTSIDE_BAND, REMOTE_CHAIN, residual, edge + 1, bandBps_));
        vm.revertToState(snap);
        _attest(edge, 2);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), edge, "the zero-baseline edge passes");
    }

    /// @dev Credit floor: with `settled` already high and no anchor or net principal, a fresh credit `c` caps the anchor
    ///      at `c`, and the floor `ceil(settled * 10_000 / (10_000 + band))` lifts it, with the executor's band.
    function _creditFloor(uint256 bandBps_) internal {
        _setUpBand(2_000, bandBps_);
        stdstore.target(address(executor)).sig("settledRemoteBalance(uint256)").with_key(REMOTE_CHAIN).checked_write(
            500e6
        );
        _settle(1e6);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 501e6, "credit added to the settled bucket");
        uint256 floor = (501e6 * 10_000 + 10_000 + bandBps_ - 1) / (10_000 + bandBps_);
        assertEq(
            executor.attestationAnchorPrincipal(REMOTE_CHAIN),
            floor,
            "the floor is ceil(settled * 10_000 / (10_000 + band)) with the executor band"
        );
    }

    /// @dev D4: the Stargate attestation library has no above-band blocking (that part is CCIP only): approving a value above the
    ///      band still reverts `AttestationOutsideAnchorBand`, the proposal stays pending and the chain is not blocked. The
    ///      operational answer is the manual `rejectAndBlockProposal` (README).
    function testShouldKeepRevertingAnApprovalAboveTheBandWithoutBlockingTheChain() public {
        _setUpBand(2_000, 10_000);
        _settle(ANCHOR);
        uint256 edge = 2 * ANCHOR;
        uint256 cur = ANCHOR;
        while ((cur * 12) / 10 < edge) {
            cur = (cur * 12) / 10;
            _attest(cur, 1);
        }
        (bool ok, bytes memory reason) = _tryAttest(edge + 1, 1);
        assertFalse(ok, "approval above the band reverts");
        assertEq(reason, abi.encodeWithSelector(OUTSIDE_BAND, REMOTE_CHAIN, ANCHOR, edge + 1, 10_000));
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "the chain is not blocked by the refused approval");
        assertEq(executor.activeProposalId(REMOTE_CHAIN), executor.proposalCount(), "the proposal stays pending");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), cur, "settled unchanged");
    }

    function testShouldUseTheExecutorBandOnTheUpperEdgeAt5000() public {
        _upEdge(5_000);
    }

    function testShouldUseTheExecutorBandOnTheUpperEdgeAt10000() public {
        _upEdge(10_000);
    }

    function testShouldUseTheExecutorBandOnTheUpperEdgeAt50000() public {
        _upEdge(50_000);
    }

    function testShouldUseTheExecutorBandOnTheLowerEdgeAt5000() public {
        _downEdge(5_000);
    }

    function testShouldHaveNoLowerEdgeAt10000() public {
        _downEdge(10_000);
    }

    function testShouldHaveNoLowerEdgeAt50000() public {
        _downEdge(50_000);
    }

    function testShouldUseTheExecutorBandOnTheZeroBaselineBranchAt5000() public {
        _zeroBaseline(5_000);
    }

    function testShouldUseTheExecutorBandOnTheZeroBaselineBranchAt10000() public {
        _zeroBaseline(10_000);
    }

    function testShouldUseTheExecutorBandOnTheZeroBaselineBranchAt50000() public {
        _zeroBaseline(50_000);
    }

    function testShouldFloorTheCreditedAnchorWithTheExecutorBandAt5000() public {
        _creditFloor(5_000);
    }

    function testShouldFloorTheCreditedAnchorWithTheExecutorBandAt10000() public {
        _creditFloor(10_000);
    }

    function testShouldFloorTheCreditedAnchorWithTheExecutorBandAt50000() public {
        _creditFloor(50_000);
    }

    /// @dev Invariant (port of `testFuzz_topUpOnResidualAlwaysLeavesAnApprovableValue`, any band in
    ///      `[bigChangeBps, 50_000]`): after an approved loss, a full recall leaving a residual and a top-up, a value the
    ///      attester pair can approve exists: `settled` itself when the pair is band-legal (zero delta), the anchor when
    ///      `settled` lies outside the band (the relative step is skipped there).
    function testFuzz_topUpOnResidualAlwaysLeavesAnApprovableValue(
        uint256 bandBps_,
        uint256 loss_,
        uint256 residual_,
        uint256 topUp_
    ) public {
        bandBps_ = bound(bandBps_, 2_000, 50_000);
        loss_ = bound(loss_, 1e6, 20e6);
        residual_ = bound(residual_, 1e6, 100e6);
        topUp_ = bound(topUp_, 1e6, 100e6);
        _setUpBand(2_000, bandBps_);
        _fullRecallLeavingResidual(loss_, residual_);
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        (bytes32 transferId, bytes32 guid, ) = _sendAsset(topUp_, 0);
        _deliverTransferSettled(transferId, guid, topUp_, 3);

        uint256 settled = executor.settledRemoteBalance(REMOTE_CHAIN);
        uint256 anchor = executor.attestationAnchorPrincipal(REMOTE_CHAIN);
        uint256 diff = settled > anchor ? settled - anchor : anchor - settled;
        bool outside = diff * 10_000 > anchor * bandBps_;
        _attest(outside ? anchor : settled, 3);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), outside ? anchor : settled, "an approvable value exists");
    }
}

/// @dev Drives the library's internal `_applyReturnDebit` with a chosen state (band included).
contract StargateBandReturnDebitHarness {
    StargateExecutorState internal s;
    mapping(bytes32 => ReturnRecord) internal recs;

    uint256 internal constant CHAIN = 1;
    bytes32 internal constant ID = bytes32(uint256(1));

    function seed(uint256 bandBps_, uint256 settled_, uint256 anchor_) external {
        s.anchorBandBps = bandBps_;
        s.settledRemoteBalance[CHAIN] = settled_;
        s.anchorPrincipal[CHAIN] = anchor_;
        recs[ID].maxAccountedSD = settled_;
    }

    function apply_(uint256 amountSentSD_) external returns (uint256) {
        return StargateExecutorAccountingLib._applyReturnDebit(s, CHAIN, ID, recs[ID], amountSentSD_, 0);
    }

    function settled() external view returns (uint256) {
        return s.settledRemoteBalance[CHAIN];
    }

    function anchor() external view returns (uint256) {
        return s.anchorPrincipal[CHAIN];
    }
}

/// @title StargateAnchorBandLibraryParamTest
/// @notice IL-9720: the clamp of `_applyReturnDebit` uses the state's band, compared with an independent
///         `(x * y + d - 1) / d` computation, at a band-legal pair on the upper edge.
contract StargateAnchorBandLibraryParamTest is StargateBandFixtureBase {
    StargateBandReturnDebitHarness internal harness;

    function setUp() public {
        harness = new StargateBandReturnDebitHarness();
    }

    function _ceilDiv(uint256 x_, uint256 y_, uint256 d_) internal pure returns (uint256) {
        return (x_ * y_ + d_ - 1) / d_;
    }

    function _debitClampAt(uint256 bandBps_) internal {
        uint256 anchor = 100e6;
        uint256 top = (anchor * (10_000 + bandBps_)) / 10_000;
        harness.seed(bandBps_, top, anchor);
        harness.apply_(1);
        uint256 settledAfter = harness.settled();
        assertEq(settledAfter, top - 1, "bucket debited by the sent amount");
        uint256 remaining = anchor - _ceilDiv(anchor, 1, top);
        if ((settledAfter - remaining) * 10_000 > remaining * bandBps_) {
            remaining = _ceilDiv(settledAfter, 10_000, 10_000 + bandBps_);
        }
        assertEq(harness.anchor(), remaining, "anchor clamped with the state band");
        assertLe(harness.anchor(), anchor, "the anchor never rises on a debit");
        assertLe(settledAfter * 10_000, harness.anchor() * (10_000 + bandBps_), "settled stays under the upper edge");
    }

    function testShouldClampTheDebitedAnchorWithTheStateBand5000() public {
        _debitClampAt(5_000);
    }

    function testShouldClampTheDebitedAnchorWithTheStateBand10000() public {
        _debitClampAt(10_000);
    }

    function testShouldClampTheDebitedAnchorWithTheStateBand50000() public {
        _debitClampAt(50_000);
    }
}

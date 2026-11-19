// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {
    CcipExecutorAttestationLib,
    CcipAttestationState
} from "../../contracts/crosschain/ccip/lib/CcipExecutorAttestationLib.sol";
import {CcipBandFixtureBase} from "./CcipLeveragedLegBandRegressionTest.t.sol";

/// @title CcipAnchorBandParamTest
/// @notice IL-9720: the geometry of the anchor band for a per-executor band, with exact numbers at 5_000, 10_000 and
///         50_000 bps: the upper and lower edge of `approve` (ordinary branch), the zero-baseline branch on a residual
///         anchor, and the fourth argument of `AttestationOutsideAnchorBand`. `bigChangeBps` is 2_000 throughout, so the
///         walk to an edge is made of ordinary steps of at most 20%.
contract CcipAnchorBandParamTest is CcipBandFixtureBase {
    uint256 internal constant ANCHOR = 100e18;

    /// @dev Walks `settled` towards the upper edge in 20% steps, then asserts that the edge passes and that the next unit
    ///      beyond it blocks the chain (IL-9720), and reverts with the executor's band once the chain is blocked.
    function _upEdge(uint256 bandBps_) internal {
        _setUpBand(2_000, bandBps_);
        _bridge(ANCHOR);
        uint256 edge = (ANCHOR * (10_000 + bandBps_)) / 10_000;
        uint256 cur = ANCHOR;
        while ((cur * 12) / 10 < edge) {
            cur = (cur * 12) / 10;
            _attest(cur);
        }
        uint256 snap = vm.snapshotState();
        // IL-9720: one unit above the edge is a value above the band: the approval does not revert, it writes nothing and
        // blocks the chain; with the chain already blocked the same approval reverts with the executor's band.
        (bool ok, ) = _tryAttest(edge + 1);
        assertTrue(ok, "one unit above the edge does not revert");
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "it blocks the chain");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), cur, "nothing was written");
        bytes memory reason;
        (ok, reason) = _tryAttest(edge + 1);
        assertFalse(ok, "the chain is blocked: the same approval reverts");
        assertEq(
            reason,
            abi.encodeWithSelector(OUTSIDE_BAND, REMOTE_CHAIN, ANCHOR, edge + 1, bandBps_),
            "the band, with the executor's band as fourth argument"
        );
        vm.revertToState(snap);
        _attest(edge);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), edge, "the edge itself passes");
    }

    /// @dev Lower edge `anchor * (1 - b)` (0 for `b >= 1`): below 100% the edge passes and the unit below is refused;
    ///      from 100% up the lower edge is zero and a long walk down never meets the band.
    function _downEdge(uint256 bandBps_) internal {
        _setUpBand(2_000, bandBps_);
        _bridge(ANCHOR);
        if (bandBps_ >= 10_000) {
            uint256 cur = ANCHOR;
            for (uint256 i; i < 12; ++i) {
                cur = (cur * 8) / 10;
                _attest(cur);
            }
            assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), cur, "no lower edge above zero at b >= 1");
            return;
        }
        uint256 edge = (ANCHOR * (10_000 - bandBps_)) / 10_000;
        uint256 cur = ANCHOR;
        while ((cur * 8) / 10 > edge) {
            cur = (cur * 8) / 10;
            _attest(cur);
        }
        uint256 snap = vm.snapshotState();
        (bool ok, bytes memory reason) = _tryAttest(edge - 1);
        assertFalse(ok, "one unit below the edge is refused");
        assertEq(reason, abi.encodeWithSelector(OUTSIDE_BAND, REMOTE_CHAIN, ANCHOR, edge - 1, bandBps_));
        vm.revertToState(snap);
        _attest(edge);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), edge, "the lower edge passes");
    }

    /// @dev Zero-baseline branch: a full recall leaves residual anchor R and `settled == 0`; a positive attestation is
    ///      bounded by the band alone around R, and a zero-baseline refusal carries the executor's band.
    function _zeroBaseline(uint256 bandBps_) internal {
        _setUpBand(2_000, bandBps_);
        _bridge(ANCHOR);
        _attest(ANCHOR);
        _accrueYield(10e18);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, ANCHOR, 0, 0, address(0), 500_000);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "bucket emptied");
        uint256 residual = executor.attestationAnchorPrincipal(REMOTE_CHAIN);
        assertEq(residual, 10e18, "the residual stays as the anchor");
        uint256 edge = (residual * (10_000 + bandBps_)) / 10_000;
        uint256 snap = vm.snapshotState();
        (bool ok, bytes memory reason) = _tryAttest(edge + 1);
        assertFalse(ok, "one unit above the zero-baseline edge is refused");
        assertEq(reason, abi.encodeWithSelector(OUTSIDE_BAND, REMOTE_CHAIN, residual, edge + 1, bandBps_));
        vm.revertToState(snap);
        _attest(edge);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), edge, "the zero-baseline edge passes");
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

    /// @dev Invariant (port of `testFuzz_topUpOnResidualAlwaysLeavesAnApprovableValue`, any band in
    ///      `[bigChangeBps, 50_000]`): after a loss, a full recall leaving a residual and a top-up, a value the attester
    ///      pair can approve exists: `settled` itself when the pair is band-legal (zero delta), the anchor when `settled`
    ///      lies outside the band (the relative step is skipped there).
    function testFuzz_topUpOnResidualAlwaysLeavesAnApprovableValue(
        uint256 bandBps_,
        uint256 loss_,
        uint256 residual_,
        uint256 topUp_
    ) public {
        bandBps_ = bound(bandBps_, 2_000, 50_000);
        loss_ = bound(loss_, 1e18, 20e18);
        residual_ = bound(residual_, 1e18, 100e18);
        topUp_ = bound(topUp_, 1e18, 100e18);
        _setUpBand(2_000, bandBps_);
        _bridge(100e18);
        _realiseLoss(loss_);
        _attest(100e18 - loss_);
        _accrueYield(residual_);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 100e18 - loss_, 0, 0, address(0), 500_000);
        _bridge(topUp_);

        uint256 settled = executor.settledRemoteBalance(REMOTE_CHAIN);
        uint256 anchor = executor.attestationAnchorPrincipal(REMOTE_CHAIN);
        uint256 diff = settled > anchor ? settled - anchor : anchor - settled;
        bool outside = diff * 10_000 > anchor * bandBps_;
        _attest(outside ? anchor : settled);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), outside ? anchor : settled, "an approvable value exists");
    }
}

/// @title CcipAnchorBandLibraryParamTest
/// @notice IL-9720: the clamp of `applyReturnDebit` and the floor of `creditAnchor` use the state's band. The library is
///         driven directly with a chosen state and compared with an independent `(x * y + d - 1) / d` computation.
contract CcipAnchorBandLibraryParamTest is Test {
    uint256 private constant CHAIN = 8453;

    CcipAttestationState internal state;
    mapping(uint256 => uint256) internal settled;

    function _ceilDiv(uint256 x_, uint256 y_, uint256 d_) internal pure returns (uint256) {
        return (x_ * y_ + d_ - 1) / d_;
    }

    function _debitClampAt(uint256 bandBps_) internal {
        state.anchorBandBps = bandBps_;
        uint256 anchor = 100e18;
        uint256 top = (anchor * (10_000 + bandBps_)) / 10_000; // band-legal pair on the upper edge
        state.anchorPrincipal[CHAIN] = anchor;
        state.netPrincipal[CHAIN] = anchor;
        settled[CHAIN] = top;
        // a 1-unit recall: the pro-rata Ceil debit shrinks the anchor faster than the bucket
        CcipExecutorAttestationLib.applyReturnDebit(state, settled, CHAIN, bytes32(uint256(1)), 1, top, 0);
        uint256 settledAfter = settled[CHAIN];
        assertEq(settledAfter, top - 1, "bucket debited by the sent amount");
        uint256 remaining = anchor - _ceilDiv(anchor, 1, top);
        if ((settledAfter - remaining) * 10_000 > remaining * bandBps_) {
            remaining = _ceilDiv(settledAfter, 10_000, 10_000 + bandBps_);
        }
        assertEq(state.anchorPrincipal[CHAIN], remaining, "anchor clamped with the state band");
        assertLe(state.anchorPrincipal[CHAIN], anchor, "the anchor never rises on a debit");
        // post-debit pair is band-legal for this band
        uint256 a = state.anchorPrincipal[CHAIN];
        assertLe(settledAfter * 10_000, a * (10_000 + bandBps_), "settled stays under the upper edge");
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

    function _creditFloorAt(uint256 bandBps_) internal {
        state.anchorBandBps = bandBps_;
        // (settled S, anchor 0, net 0) and a credit c that is already inside S: the cap min(anchor + c, net) = c is below the floor
        uint256 s = 500e18;
        settled[CHAIN] = s;
        CcipExecutorAttestationLib.creditAnchor(state, settled, CHAIN, 1e18);
        assertEq(state.netPrincipal[CHAIN], 1e18);
        assertEq(
            state.anchorPrincipal[CHAIN],
            _ceilDiv(s, 10_000, 10_000 + bandBps_),
            "the floor is ceil(settled * 10_000 / (10_000 + band)) with the state band"
        );
    }

    function testShouldFloorTheCreditedAnchorWithTheStateBand5000() public {
        _creditFloorAt(5_000);
    }

    function testShouldFloorTheCreditedAnchorWithTheStateBand10000() public {
        _creditFloorAt(10_000);
    }

    function testShouldFloorTheCreditedAnchorWithTheStateBand50000() public {
        _creditFloorAt(50_000);
    }

    /// @dev Pinning the pitfall of IL-9720: a state that was never given a band (0) has a floor equal to `settled`
    ///      and rejects every positive attestation; the executor constructor always sets it, harnesses must.
    function testShouldTreatAnUnsetBandAsZero() public {
        settled[CHAIN] = 500e18;
        CcipExecutorAttestationLib.creditAnchor(state, settled, CHAIN, 1e18);
        assertEq(state.anchorPrincipal[CHAIN], 500e18, "band 0: the floor equals settled");
    }
}

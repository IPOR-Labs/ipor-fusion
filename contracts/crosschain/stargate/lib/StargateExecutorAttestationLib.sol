// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {CrosschainConstants} from "../../lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../lib/CrosschainErrors.sol";
import {
    StargateExecutorState,
    Proposal,
    PROPOSAL_PENDING,
    PROPOSAL_APPROVED,
    PROPOSAL_REJECTED,
    PROPOSAL_SUPERSEDED
} from "./StargateExecutorState.sol";

/// @title StargateExecutorAttestationLib
/// @notice The `StargateCrosschainExecutor` two-step settled-balance attestation engine, extracted into an
///         external linked library to keep the executor under the EIP-170 runtime limit (spec §9, §12).
///         Operates on `StargateExecutorState storage self` via delegatecall; behavior is identical to the
///         previously-inlined implementation.
/// @dev Role authorization (`BALANCE_PROPOSER` / `BALANCE_APPROVER`), the `hasDispatcher` precondition
///      and the monotonic `proposalId` allocation stay on the executor (which owns the immutables and
///      the local<->shared decimal conversion). These functions carry the post-auth logic bodies only.
/// @author IPOR Labs
library StargateExecutorAttestationLib {
    /// @notice IL-8631 / TP-L-03: the observation's remaining freshness (`remoteTimestamp + stalenessMax -
    ///         now`) is shorter than `minUpdateInterval`, so it would go stale before the next approval is
    ///         permitted (NAV would freeze with `NavSettledStale`). Take a fresher observation.
    error ObservationTooCloseToStale(uint256 chainId, uint64 remoteTimestamp);
    /// @notice IL-8648 / TP-L-20: the proposal's observation is older than the one already approved for the
    ///         chain; approving it would roll the NAV freshness clock backwards.
    error ObservationOlderThanApproved(uint256 chainId, uint64 remoteTimestamp, uint64 lastApprovedObservedAt);

    /// @dev Carries the FULL approved observation so a monitor can reconstruct it without reading
    ///      historical calldata (§9 P1 item 7): remote block/timestamp, expiry and the tracked-position
    ///      set hash the approver is expected to have verified off-chain.
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
    event BalanceApproved(uint256 proposalId, uint256 chainId, uint256 settledSD, uint64 remoteTimestamp);
    event BalanceRejectedAndBlocked(uint256 proposalId, uint256 chainId);
    /// @notice An approval lifted the fail-closed chain block raised by ADVANCE_STATE_FRONTIER (the
    ///         frontier-repair latch). Emitted in the same transaction as `BalanceApproved`.
    event ChainUnblockedByApproval(uint256 chainId, uint256 proposalId);
    /// @notice The per-chain accounting anchor was reset to zero by a dust-to-zero attestation (IL-8499).
    ///         Same signature as `StargateExecutorAccountingLib.AttestationAnchorUpdated`.
    event AttestationAnchorUpdated(uint256 chainId, uint256 principalSD);
    /// @notice The per-chain net principal (`netPrincipal`, IL-8578 / TP-H-02) changed: a credit, a recall
    ///         debit, a force-set rebase or the dust-to-zero reset. `netPrincipalSD` is the NEW value, in
    ///         shared decimals.
    event AttestationNetPrincipalUpdated(uint256 chainId, uint256 netPrincipalSD);
    /// @notice An active balance proposal was voided without being approved or rejected, so it can no longer
    ///         be approved: either an accounting-epoch bump (a value-moving operation made the observed
    ///         snapshot stale, IL-8269) or a newer proposal for the same chain replaced it (IL-8472). The
    ///         proposal's status becomes SUPERSEDED (4) and approve / reject of it reverts `ProposalNotActive`.
    ///         `newEpoch` is the chain's accounting epoch after the void (the current epoch when a newer
    ///         proposal supersedes it).
    event ProposalInvalidated(uint256 chainId, uint256 proposalId, uint64 newEpoch);

    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @dev Create a pending proposal. `settledSD_` is the observed settled balance already converted to
    ///      shared decimals; `proposalId_` was allocated by the executor (`++proposalCount`).
    function propose(
        StargateExecutorState storage self,
        uint256 chainId_,
        uint256 settledSD_,
        uint64 stateVersion_,
        uint64 remoteBlock_,
        uint64 remoteTimestamp_,
        uint64 expiry_,
        bytes32 trackedPositionSetHash_,
        uint256 stalenessMax_,
        uint256 proposalId_
    ) public {
        // Require the observation's version to sit exactly on the contiguous receipt frontier: an
        // observer cannot attest a remote transition while any earlier receipt is missing (§9).
        if (stateVersion_ != self.acknowledgedRemoteStateVersion[chainId_]) {
            revert CrosschainErrors.ProposalVersionMismatch(
                self.acknowledgedRemoteStateVersion[chainId_],
                stateVersion_
            );
        }
        // Metadata completeness: a real observation always carries a nonzero remote block and timestamp;
        // a zero value is uninitialized/forged and would make BalanceObservation decorative (§9 P1).
        if (remoteBlock_ == 0) revert CrosschainErrors.InvalidObservationMetadata(chainId_);
        if (remoteTimestamp_ == 0) revert CrosschainErrors.InvalidObservationMetadata(chainId_);
        // A future observation timestamp is impossible for a real remote read; reject it (§9 P1 item 3).
        if (remoteTimestamp_ > block.timestamp) revert CrosschainErrors.InvalidObservationMetadata(chainId_);
        if (expiry_ <= block.timestamp) revert CrosschainErrors.ProposalExpired(0);
        // Minimum approval window: `expiry` must leave a meaningful amount of time for the approver to
        // act, otherwise a proposer could emit proposals (e.g. `expiry = block.timestamp + 1`) that are
        // practically impossible to approve in a normal multisig/keeper cycle (V2-02).
        uint256 approvalWindow = expiry_ - block.timestamp;
        if (approvalWindow < CrosschainConstants.MIN_PROPOSAL_APPROVAL_WINDOW) {
            revert CrosschainErrors.ProposalApprovalWindowTooShort(
                chainId_,
                approvalWindow,
                CrosschainConstants.MIN_PROPOSAL_APPROVAL_WINDOW
            );
        }
        // Freshness: an observation already older than STALENESS_MAX cannot enter NAV (§9). Checked here
        // AND re-checked in approve() against the persisted remoteTimestamp (§9 P1 item 5).
        if (block.timestamp - remoteTimestamp_ > stalenessMax_) {
            revert CrosschainErrors.ObservationStale(chainId_);
        }

        // A newer proposal replaces the active one: mark the old one SUPERSEDED so its stored status matches
        // its `ProposalNotActive` behaviour, and tell monitors (IL-8472).
        uint256 oldId = self.activeProposalId[chainId_];
        if (oldId != 0 && oldId != proposalId_ && self.proposals[oldId].status == PROPOSAL_PENDING) {
            self.proposals[oldId].status = PROPOSAL_SUPERSEDED;
            emit ProposalInvalidated(chainId_, oldId, self.accountingEpoch[chainId_]);
        }
        self.proposals[proposalId_] = Proposal({
            chainId: chainId_,
            settledSD: settledSD_,
            stateVersion: stateVersion_,
            remoteBlock: remoteBlock_,
            remoteTimestamp: remoteTimestamp_,
            expiry: expiry_,
            trackedPositionSetHash: trackedPositionSetHash_,
            accountingEpochSnapshot: self.accountingEpoch[chainId_],
            status: PROPOSAL_PENDING
        });
        self.activeProposalId[chainId_] = proposalId_;
        emit BalanceProposed(
            proposalId_,
            chainId_,
            settledSD_,
            stateVersion_,
            remoteBlock_,
            remoteTimestamp_,
            expiry_,
            trackedPositionSetHash_
        );
    }

    /// @dev Approve a pending proposal, overwriting the settled bucket ONLY (never in-flight). Immutable
    ///      thresholds (`bigChangeBps_`, `minUpdateInterval_`) are passed by the executor.
    /// @dev In addition to the per-approval RELATIVE bound (`bigChangeBps_`), the approved value must sit
    ///      within `CrosschainConstants.ATTESTATION_ANCHOR_BAND_BPS` of `self.anchorPrincipal[chainId]`
    ///      (IL-7967, audit `no_cumulative_bound_on_attested_balance_ratchet`): `bigChangeBps_` alone
    ///      bounds one step, not the number of steps, so `n` compliant approvals compound to
    ///      `(1 ± bigChangeBps_/10_000)^n` — unbounded given enough rounds. `anchorPrincipal` is credited
    ///      only by peer-authenticated accounting and the timelocked `forceSetSettled` rebase, so the band
    ///      check is checked AFTER `BigChangeExceeded` (so that revert keeps firing first and every
    ///      existing expectation holds) and turns the attester pair from "sets remote NAV" into "sets
    ///      remote NAV within the band of value the vault verifiably sent". The freshness marker
    ///      (`lastApprovedObservedAt`) is refreshed by every approval, proposer-supplied — it bounds how
    ///      long the walk may pause, not how far it may go; the band is what bounds the distance.
    function approve(
        StargateExecutorState storage self,
        uint256 proposalId_,
        uint256 bigChangeBps_,
        uint256 minUpdateInterval_,
        uint256 stalenessMax_
    ) public {
        Proposal storage p = self.proposals[proposalId_];
        uint256 chainId = p.chainId;
        if (p.status != PROPOSAL_PENDING || self.activeProposalId[chainId] != proposalId_) {
            revert CrosschainErrors.ProposalNotActive(proposalId_);
        }
        if (block.timestamp > p.expiry) revert CrosschainErrors.ProposalExpired(proposalId_);
        // Re-check freshness at approval time: a proposal fresh when proposed but now older than
        // STALENESS_MAX (measured against its REMOTE observation timestamp) must not enter NAV (§9 P1
        // item 5). This makes a stale observation unapprovable even before its `expiry`.
        if (block.timestamp - p.remoteTimestamp > stalenessMax_) revert CrosschainErrors.ObservationStale(chainId);
        // IL-8631 / TP-L-03: the next approval is rate-limited for `minUpdateInterval_` from THIS one, so the
        // observation must stay fresh for at least that long, or NAV freezes between the two. Applies to the
        // first approval and the repair-latch approval too (both are followed by a rate-limited approval).
        if (uint256(p.remoteTimestamp) + stalenessMax_ < block.timestamp + minUpdateInterval_) {
            revert ObservationTooCloseToStale(chainId, p.remoteTimestamp);
        }
        // IL-8648 / TP-L-20: the freshness clock is monotonic; an older observation
        // than the approved one is rejected rather than rolling the clock back.
        if (p.remoteTimestamp < self.lastApprovedObservedAt[chainId]) {
            revert ObservationOlderThanApproved(chainId, p.remoteTimestamp, self.lastApprovedObservedAt[chainId]);
        }
        if (p.accountingEpochSnapshot != self.accountingEpoch[chainId]) {
            revert CrosschainErrors.ProposalEpochChanged(chainId);
        }
        if (p.stateVersion != self.acknowledgedRemoteStateVersion[chainId]) {
            revert CrosschainErrors.ProposalVersionMismatch(
                self.acknowledgedRemoteStateVersion[chainId],
                p.stateVersion
            );
        }

        // IL-8614 / TP-M-36: after a frontier repair a lost TRANSFER_SETTLED may leave its outbound record in
        // `outboundInFlight` while the attested balance already contains the delivered amount (S + 2A). Refuse
        // to write `settled` until the record is closed (replayed settle or force-resolve).
        if (self.frontierRepairPending[chainId] && self.outboundInFlight[chainId] != 0) {
            revert CrosschainErrors.FrontierRepairBlockedByOpenTransfers(chainId, self.outboundInFlight[chainId]);
        }

        uint256 oldSettled = self.settledRemoteBalance[chainId];
        uint256 newSettled = p.settledSD;
        // A delta above BIG_CHANGE_BPS cannot use normal approval — must reject-and-block (§9).
        if (oldSettled == 0) {
            // `bigChangeBps_` is RELATIVE, so a zero baseline bounds nothing and one approval could write
            // an arbitrary NAV (audit `no_cumulative_bound_on_attested_balance_ratchet`, filed against
            // CCIP only — this transport had the identical hole). The window re-opens after every full
            // recall, not only before the first attestation, because `_applyReturnDebit` drains the bucket.
            // With no anchor to bound against, the untrusted proposer/approver pair must not be able to
            // leave zero: an authenticated TRANSFER_SETTLED credits `settled` directly, and
            // `forceSetSettled` overwrites it behind the timelock. Zero-to-zero stays allowed.
            //
            // The baseline is the ANCHOR, not the bucket (IL-8606 / TP-M-28): a full recall of a bucket whose
            // remote side kept earning leaves a dispatcher-authenticated residual above the dust bound, and
            // `_applyReturnDebit` then keeps the anchor at that residual while `settled` is 0. From such a
            // state a positive attestation is bounded by the anchor band alone (the relative check is
            // meaningless at a zero baseline), so the residual can be priced without the timelocked
            // force-set. With no anchor the zero-baseline rule above is unchanged.
            if (newSettled != 0) {
                if (self.anchorPrincipal[chainId] == 0) {
                    revert CrosschainErrors.UnanchoredAttestation(chainId, newSettled);
                }
                _requireWithinAnchorBand(self, chainId, newSettled);
            }
        } else if (newSettled == 0 && oldSettled <= CrosschainConstants.ATTESTATION_ZERO_DUST_SD) {
            // IL-8499 / IL-8424 #6: rounding dust left by a full recall (dispatcher already reports 0)
            // could otherwise only be cleared by the timelocked force-set, because dust -> 0 is a 100%
            // relative change. Exactly-zero, at or below an absolute bound: skip the relative and band
            // checks and reset the anchor with the bucket (they reach zero together). Cannot raise NAV.
            self.anchorPrincipal[chainId] = 0;
            self.netPrincipal[chainId] = 0;
            emit AttestationAnchorUpdated(chainId, 0);
            emit AttestationNetPrincipalUpdated(chainId, self.netPrincipal[chainId]);
        } else {
            // IL-8792: the relative check applies only while `oldSettled` is itself a baseline, i.e. inside
            // the anchor band (outside the band on either side skips it; only below is
            // reachable). After an anchor credit on a `(settled 0, anchor R)` pair with `net > 0` (an approved loss),
            // `oldSettled = c` can sit BELOW the band (iff `c < 4 * min(R, net)`) and the `BigChangeExceeded`
            // window around it can be disjoint from the band (the pre-fix freeze) iff
            // `c * (1 + bigChangeBps_ / 10_000) < 0.8 * (min(R, net) + c)`, e.g. `c < 8/3 * min(R, net)` at 10%
            // (no approvable value, NAV frozen at `BALANCE_STALENESS_MAX`). Such an `oldSettled` is
            // not a baseline, like `oldSettled == 0` (IL-8606), so the band alone bounds the approval. The
            // relative check returns after the first band approval. See `_outsideAnchorBand`.
            uint256 principal = self.anchorPrincipal[chainId];
            if (principal == 0 || !_outsideAnchorBand(oldSettled, principal)) {
                uint256 diff = newSettled > oldSettled ? newSettled - oldSettled : oldSettled - newSettled;
                if (diff * BPS_DENOMINATOR > oldSettled * bigChangeBps_) {
                    revert CrosschainErrors.BigChangeExceeded(oldSettled, newSettled, bigChangeBps_);
                }
            }
            _requireWithinAnchorBand(self, chainId, newSettled);
        }
        // Rate-limit against the LOCAL approval cadence (a separate marker from the freshness one).
        uint64 lastApproval = self.lastApprovalAt[chainId];
        if (lastApproval != 0 && block.timestamp - lastApproval < minUpdateInterval_) {
            revert CrosschainErrors.MinUpdateIntervalNotMet(lastApproval, block.timestamp, minUpdateInterval_);
        }

        // Overwrite the settled bucket ONLY — never any in-flight bucket (invariant #2).
        self.settledRemoteBalance[chainId] = newSettled;
        // NAV freshness is anchored to the REMOTE observation time, so settled becomes stale relative to
        // when the value was observed, not when it happened to be approved (§9 P1 item 4).
        self.lastApprovedObservedAt[chainId] = p.remoteTimestamp;
        self.lastApprovalAt[chainId] = SafeCast.toUint64(block.timestamp);
        p.status = PROPOSAL_APPROVED;
        self.activeProposalId[chainId] = 0;
        // IL-8621: an attestation bound to a dispatcher version PAST the one acknowledged when a recall was
        // cancelled was read after the dispatcher's later state changes (a bridged recall bumps its version),
        // so it prices the recall and the cancelled-recall clock can go. An attestation at the cancel-time
        // version (or older) proves nothing about the recall and leaves the clock armed.
        if (self.cancelledRecallCount[chainId] != 0 && p.stateVersion > self.cancelledRecallVersion[chainId]) {
            delete self.cancelledRecallCount[chainId];
            delete self.cancelledRecallPendingAt[chainId];
            ++self.cancelledRecallGeneration[chainId];
        }
        if (self.frontierRepairPending[chainId]) {
            self.frontierRepairPending[chainId] = false;
            self.chainBlocked[chainId] = false;
            emit ChainUnblockedByApproval(chainId, proposalId_);
        }
        emit BalanceApproved(proposalId_, chainId, newSettled, p.remoteTimestamp);
    }

    /// @dev Enforce the anchored band (IL-7967). `>` reverts, `==` passes, same convention as
    ///      `BigChangeExceeded`. `principal == 0` degenerates to requiring `newSettled == 0`, which is
    ///      already what `UnanchoredAttestation` enforces in the `oldSettled == 0` branch of `approve`.
    ///      `oldSettled != 0 && principal == 0` cannot occur: `principal` reaches zero only together with
    ///      `oldSettled`. Every write that moves `settledRemoteBalance` outside `approve` moves
    ///      `anchorPrincipal` in the same statement block: `_setSettled` rebases both, the force-resolve
    ///      credit, `_onTransferSettled` and `_applyLateCredit` move the anchor through `_creditAnchor`, whose
    ///      band floor leaves it >= `ceil(settledAfter * 10_000 / 12_000)` >= 1, and `_applyReturnDebit`
    ///      debits both. That debit's band-consistency clamp leaves an anchor of at least 1 whenever a
    ///      residue survives.
    /// @dev The clamp is what makes the band self-consistent on the recall path. `Ceil` rounding in the
    ///      pro-rata debit shrinks the anchor faster than the bucket, so an un-clamped pair could land outside
    ///      the band and the band window and the `BigChangeExceeded` window would be disjoint (a permanent
    ///      attestation freeze, reachable by an ordinary recall that returns a few SD units short). The clamp
    ///      re-anchors so that the post-debit pair satisfies the band, hence `settledAfter` itself is an
    ///      approvable value. Swept over the reachable `(principal, settled, debit)` space in
    ///      `audit/IL-7942/IL-7967/anchor_band_sweep.py`. The clamp only ever raises the anchor to the MINIMUM
    ///      band-restoring value, which that induction bounds by the pre-debit principal, so it cannot be used
    ///      to walk the anchor upward.
    /// @dev IL-8792: the induction "the pair is band-legal after every paired write" missed an anchor CREDIT
    ///      on a `(settled 0, anchor R)` pair. The credit floor keeps `settledAfter <= 1.2 * anchor` but
    ///      nothing keeps `settledAfter >= 0.8 * anchor`: with `net > 0` the cap `min(R, net) + c` leaves
    ///      `settled = c` below the band iff `c < 4 * min(R, net)`, and the windows are disjoint (the pre-fix
    ///      freeze) iff `c * (1 + bigChangeBps / 10_000) < 0.8 * (min(R, net) + c)`. `approve` therefore skips the relative check
    ///      when `oldSettled` lies outside the band (only below is reachable: the credit floor keeps
    ///      `settled <= 1.2 * anchor`, and approve, the rebase and the clamped debit keep an in-band pair in the band; an
    ///      above-band `oldSettled` would skip it too; it is not a baseline, like zero) and this predicate alone
    ///      bounds the value, so an approvable value always exists. Approve and the rebase leave the pair in the
    ///      band and the clamped debit preserves band-legality of an in-band pair; a pair put below the band
    ///      by such a credit stays there (further credits, partial debits) until the next approval.
    function _requireWithinAnchorBand(
        StargateExecutorState storage self,
        uint256 chainId_,
        uint256 newSettled_
    ) private view {
        uint256 principal = self.anchorPrincipal[chainId_];
        if (_outsideAnchorBand(newSettled_, principal)) {
            revert CrosschainErrors.AttestationOutsideAnchorBand(
                chainId_,
                principal,
                newSettled_,
                CrosschainConstants.ATTESTATION_ANCHOR_BAND_BPS
            );
        }
    }

    /// @dev True when `value_` lies strictly outside `+-ATTESTATION_ANCHOR_BAND_BPS` of `anchor_`.
    function _outsideAnchorBand(uint256 value_, uint256 anchor_) private pure returns (bool) {
        uint256 diff = value_ > anchor_ ? value_ - anchor_ : anchor_ - value_;
        return diff * BPS_DENOMINATOR > anchor_ * CrosschainConstants.ATTESTATION_ANCHOR_BAND_BPS;
    }

    /// @dev Reject a pending proposal and block the chain (fail-closed NAV) until a timelocked unblock.
    function reject(StargateExecutorState storage self, uint256 proposalId_) public {
        Proposal storage p = self.proposals[proposalId_];
        uint256 chainId = p.chainId;
        if (p.status != PROPOSAL_PENDING || self.activeProposalId[chainId] != proposalId_) {
            revert CrosschainErrors.ProposalNotActive(proposalId_);
        }
        p.status = PROPOSAL_REJECTED;
        self.activeProposalId[chainId] = 0;
        self.chainBlocked[chainId] = true;
        self.blockRaisedByNoClockReturn[chainId] = false;
        // Raising a NAV block discards any pending frontier-repair latch: this block is documented to stand
        // until a timelocked unblock, and a latch left over from an earlier repair would let the very role
        // that tripped the breaker lift it again with one more propose/approve round, with no RESCUE_DELAY
        // and no guardian veto window (audit
        // `stale_frontier_repair_flag_lifts_unrelated_fail_closed_chain_block`). The repair's own exit is
        // then the timelocked `forceSetSettled`, which is where an unverifiable claim belongs.
        self.frontierRepairPending[chainId] = false;
        emit BalanceRejectedAndBlocked(proposalId_, chainId);
    }
}

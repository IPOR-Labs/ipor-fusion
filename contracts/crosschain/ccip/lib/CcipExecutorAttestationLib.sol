// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {CcipDecimalsLib} from "./CcipDecimalsLib.sol";
import {CrosschainConstants} from "../../lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../lib/CrosschainErrors.sol";

struct CcipBalanceProposal {
    uint256 chainId;
    uint256 balance;
    uint64 stateVersion;
    uint64 remoteBlock;
    uint64 remoteTimestamp;
    uint64 expiry;
    uint64 accountingEpoch;
    /// @dev Off-chain verification commitment: the dispatcher's tracked-position-set hash at observation
    ///      time. Persisted and emitted for the approver; never checked on-chain (audit M-1).
    bytes32 trackedPositionSetHash;
    uint8 status;
}

struct CcipAttestationState {
    mapping(uint256 => uint64) lastApprovedObservedAt;
    mapping(uint256 => uint64) lastApprovalAt;
    mapping(uint256 => uint64) accountingEpoch;
    mapping(uint256 => uint256) activeProposalId;
    mapping(uint256 => CcipBalanceProposal) proposals;
    uint256 proposalCount;
    // Accounting anchor (IL-7967, audit `no_cumulative_bound_on_attested_balance_ratchet`): value the
    // vault has verifiably placed on the remote chain, net of verified returns, as far as the executor
    // can know it. Written ONLY by peer-authenticated credit/debit accounting
    // (`CcipExecutorTransferLib._applyFreshSettle` / `_applyLateCredit` / this lib's `applyReturnDebit`,
    // and `CcipExecutorTransferLib.applyForceResolveOutbound`'s credit) and by the timelocked
    // `forceSetSettled` rebase below, plus the dust-to-zero reset in `approve` (an attested balance of exactly
    // zero while `settled <= ATTESTATION_ZERO_DUST_SD`: the anchor is zeroed together with a bucket that is
    // already dust, so it can never be raised or moved elsewhere). The attester pair otherwise never writes
    // it. `approve` bounds every approved
    // balance to within `CrosschainConstants.ATTESTATION_ANCHOR_BAND_BPS` of this value.
    mapping(uint256 => uint256) anchorPrincipal;
    // Net principal (IL-8578 / TP-H-02): credits from peer-authenticated settles, debited by the
    // authenticated amount the dispatcher sent back on each recall (floored at zero), rebased to
    // `newSettled` by `forceSetSettled` and zeroed with the anchor on the dust-to-zero approval. The
    // attesters never raise it: only authenticated returns lower it, and the dust-to-zero approval zeroes it
    // with the anchor. Caps every anchor CREDIT (`creditAnchor`) so a recall / re-supply round trip cannot
    // ratchet the anchor above the
    // largest net principal the vault has verifiably placed since the last force-set (the pro-rata
    // recall debit shrinks the anchor by less than the principal removed whenever `settled` carries
    // unrecognised yield, so crediting the anchor in full on re-supply would add band headroom for free).
    mapping(uint256 => uint256) netPrincipal;
    // Local `block.timestamp` at which the executor last applied a value-moving dispatcher response for the chain
    // (TRANSFER_SETTLED credit, late credit, RETURN_TRANSFER debit, outbound force-resolve, settled force-set).
    // A proposal whose remote observation is not strictly later than this was taken before that response
    // changed the dispatcher state it describes, so it can be neither proposed nor approved (IL-8604 / IL-8584),
    // and a `FORCE_SET_SETTLED` committing such an observation cannot be scheduled (IL-8604 R1).
    // Appended after the earlier members (later IL-8619 fields follow it): they keep their slots, while the
    // executor variables declared after `_attestationState` move down one slot. Harmless: the executor is
    // constructor-deployed and not upgradeable.
    mapping(uint256 => uint64) lastValueMovingReceiptAt;
    /// @dev IL-8619: per-chain repair / force-set sequence, bumped only by the latch-clearing approval (in
    ///      `approveWithRepair`, the body of `CcipCrosschainExecutor.approveBalance`) and by `forceSetSettled`;
    ///      strictly ordered within a block, so a force-resolved outbound can tell whether such a write priced it
    ///      afterwards.
    mapping(uint256 => uint64) repairSettleSeq;
    /// @dev IL-8619 review: the dispatcher `stateVersion` the latest `repairSettleSeq` write was bound to (the approved
    ///      proposal's version or the force-set's observed version, both equal to the frontier at that write). Only a
    ///      late settlement whose version is not above it can be contained in that write. Appended last.
    mapping(uint256 => uint64) repairSettleVersion;
}

library CcipExecutorAttestationLib {
    /// @dev `CcipBalanceProposal.status` values: 1 = PENDING, 2 = APPROVED, 3 = REJECTED, 4 = SUPERSEDED
    ///      (voided by an accounting-epoch bump or a newer proposal, IL-8472).
    uint8 private constant PROPOSAL_PENDING = 1;
    uint8 private constant PROPOSAL_APPROVED = 2;
    uint8 private constant PROPOSAL_REJECTED = 3;
    uint8 private constant PROPOSAL_SUPERSEDED = 4;

    error ProposalNotActive(uint256 proposalId);
    error ProposalExpired(uint256 proposalId);
    error ObservationStale(uint256 chainId);
    /// @notice IL-8631 / TP-L-03: the observation's remaining freshness (`remoteTimestamp + stalenessMax - now`)
    ///         is shorter than `minUpdateInterval`, so it would go stale before the next approval is permitted
    ///         (NAV would freeze). Take a fresher observation.
    error ObservationTooCloseToStale(uint256 chainId, uint64 remoteTimestamp);
    /// @notice IL-8648 / TP-L-20: the proposal's observation is older than the one already approved for the
    ///         chain; approving it would roll the NAV freshness clock backwards.
    error ObservationOlderThanApproved(uint256 chainId, uint64 remoteTimestamp, uint64 lastApprovedObservedAt);
    /// @notice IL-8648 R1: a strict `FORCE_SET_SETTLED` committed an observation time older than the chain's
    ///         `lastApprovedObservedAt` (an ordinary approval with a newer read landed during the rescue delay);
    ///         executing it would roll the NAV freshness clock backwards and replace the fresher figure with the
    ///         older one. Reschedule from a fresh read, or schedule `FORCE_SET_SETTLED_UNCHECKED` on purpose.
    error ForceSetOlderThanApproved(uint256 chainId, uint64 committedObservedAt, uint64 lastApprovedObservedAt);
    error ProposalVersionMismatch(uint64 expected, uint64 received);
    error ProposalEpochChanged(uint256 chainId);
    /// @notice Thrown when a balance proposal's remote observation (`remoteTimestamp`), at propose or approve, or
    ///         the observation time committed by a `FORCE_SET_SETTLED` schedule (IL-8604 R1) is not strictly later
    ///         than the moment the executor last applied a value-moving dispatcher response for the chain
    ///         (IL-8604 / IL-8584). The dispatcher versions a queued `RETURN_TRANSFER` when it is enqueued, so an
    ///         observation taken before the response was flushed shares its `stateVersion` with the post-flush
    ///         state yet still includes the returned value; crediting it again would double count. After a
    ///         value-moving receipt the attester pair must take a fresh observation.
    error ObservationPredatesValueMovingReceipt(uint256 chainId, uint64 remoteTimestamp, uint64 receiptAt);
    error BigChangeExceeded(uint256 oldBalance, uint256 newBalance, uint256 maximumBps);
    error MinUpdateIntervalNotMet(uint64 previous, uint256 current, uint256 minimum);
    error UnanchoredAttestation(uint256 chainId, uint256 proposed);
    error PendingTransfersExist(uint256 chainId, uint256 pending);
    /// @notice Thrown when an approved attestation would move `settled` outside `ATTESTATION_ANCHOR_BAND_BPS`
    ///         of the per-chain accounting anchor (`anchorPrincipal`) — CCIP transport (audit
    ///         `no_cumulative_bound_on_attested_balance_ratchet`, IL-7967).
    error AttestationOutsideAnchorBand(uint256 chainId, uint256 principal, uint256 proposed, uint256 bandBps);
    /// @notice Thrown when a settled-balance force-set was observed at a dispatcher state version other than
    ///         the acknowledged frontier, so it may count a remote debit this side has not applied yet
    ///         (IL-8294). Same selector as `CrosschainErrors.ForceSetStateVersionMismatch` on Stargate.
    error ForceSetStateVersionMismatch(uint256 chainId, uint64 acknowledged, uint64 observed);

    /// @dev Emitted from the linked library so the executor spends no bytes on it (EIP-170 headroom).
    event SettledBalanceForceSet(uint256 chainId, uint256 newSettled);
    /// @notice The per-chain accounting anchor (`anchorPrincipal`) was rebased by the timelocked
    ///         `forceSetSettled` rescue (IL-7967, audit `no_cumulative_bound_on_attested_balance_ratchet`).
    event AttestationAnchorRebased(uint256 chainId, uint256 principalSD);
    /// @notice The per-chain accounting anchor changed by a non-rebase path: a settle credit, a
    ///         DELIVERED_TO_SETTLED force-resolve credit, a pro-rata recall debit (IL-8466) or the
    ///         dust-to-zero reset in `approve` (new anchor 0, only while `settled` is within the dust bound). The
    ///         timelocked force-set rebase emits `AttestationAnchorRebased` instead. `principalSD` is the
    ///         NEW anchor, in shared decimals.
    event AttestationAnchorUpdated(uint256 chainId, uint256 principalSD);
    /// @notice The per-chain net principal (`netPrincipal`, IL-8578 / TP-H-02) changed: a credit, a recall
    ///         debit, a force-set rebase or the dust-to-zero reset. `netPrincipalSD` is the NEW value, in
    ///         shared decimals. Emitted next to `AttestationAnchorUpdated` / `AttestationAnchorRebased`.
    event AttestationNetPrincipalUpdated(uint256 chainId, uint256 netPrincipalSD);
    /// @notice A `RETURN_TRANSFER` declared more than the bound on its settled debit, which is
    ///         `min(maxAccounted, settled)`: the recall's accounted bound or what the settled bucket still
    ///         holds (IL-8497, IL-8572). The debit was clamped to `bound`. Mirrors Stargate's alarm.
    event ReturnDebitExceededAccountingBound(uint256 chainId, bytes32 operationId, uint256 sentSD, uint256 bound);
    /// @notice Mirrors of the executor events and error of `approveWithRepair` (emitted from / reverting in the
    ///         executor's context under delegatecall).
    event BalanceApproved(uint256 proposalId, uint256 chainId, uint256 balance);
    event ChainUnblockedByApproval(uint256 chainId, uint256 proposalId);
    /// @notice Mirror of the executor's event (delegatecalled log is indistinguishable).
    event BalanceRejectedAndBlocked(uint256 proposalId, uint256 chainId);
    error FrontierRepairBlockedByOpenTransfers(uint256 chainId, uint256 outboundInFlight);
    /// @notice An active balance proposal was voided without being approved or rejected, so it can no longer
    ///         be approved: either an accounting-epoch bump (a value-moving operation made the observed
    ///         snapshot stale, IL-8269) or a newer proposal for the same chain replaced it (IL-8472). The
    ///         proposal's status becomes SUPERSEDED (4) and approve / reject of it reverts `ProposalNotActive`.
    ///         `newEpoch` is the chain's accounting epoch after the void (the current epoch when a newer
    ///         proposal supersedes it).
    event ProposalInvalidated(uint256 chainId, uint256 proposalId, uint64 newEpoch);

    /// @dev Records a new balance proposal for `chainId_` and supersedes the chain's active one. Reverts
    ///      `ProposalExpired(0)` when `expiry_` is not in the future, and `ProposalApprovalWindowTooShort`
    ///      (`CrosschainErrors`, the same error as the Stargate executor) when it leaves less than
    ///      `MIN_PROPOSAL_APPROVAL_WINDOW` for the approver to act (IL-9023).
    function propose(
        CcipAttestationState storage self,
        mapping(uint256 => uint64) storage versions_,
        uint256 stalenessMax_,
        uint256 chainId_,
        uint256 balanceSD_,
        uint64 stateVersion_,
        uint64 remoteBlock_,
        uint64 remoteTimestamp_,
        uint64 expiry_,
        bytes32 trackedPositionSetHash_
    ) public returns (uint256 id) {
        uint64 current = versions_[chainId_];
        if (stateVersion_ != current) revert ProposalVersionMismatch(current, stateVersion_);
        if (
            remoteBlock_ == 0 ||
            remoteTimestamp_ == 0 ||
            remoteTimestamp_ > block.timestamp ||
            block.timestamp - remoteTimestamp_ > stalenessMax_
        ) revert ObservationStale(chainId_);
        _requireObservedAfterReceipt(self, chainId_, remoteTimestamp_);
        if (expiry_ <= block.timestamp) revert ProposalExpired(0);
        {
            // Scoped: a function-level local would push `propose` over the stack limit (no `via_ir`).
            uint256 window = expiry_ - block.timestamp;
            if (window < CrosschainConstants.MIN_PROPOSAL_APPROVAL_WINDOW) {
                revert CrosschainErrors.ProposalApprovalWindowTooShort(
                    chainId_,
                    window,
                    CrosschainConstants.MIN_PROPOSAL_APPROVAL_WINDOW
                );
            }
        }
        // A newer proposal replaces the active one: mark the old one SUPERSEDED and tell monitors (IL-8472).
        uint256 oldId = self.activeProposalId[chainId_];
        if (oldId != 0 && self.proposals[oldId].status == PROPOSAL_PENDING) {
            self.proposals[oldId].status = PROPOSAL_SUPERSEDED;
            emit ProposalInvalidated(chainId_, oldId, self.accountingEpoch[chainId_]);
        }
        id = ++self.proposalCount;
        self.proposals[id] = CcipBalanceProposal({
            chainId: chainId_,
            balance: balanceSD_,
            stateVersion: stateVersion_,
            remoteBlock: remoteBlock_,
            remoteTimestamp: remoteTimestamp_,
            expiry: expiry_,
            accountingEpoch: self.accountingEpoch[chainId_],
            trackedPositionSetHash: trackedPositionSetHash_,
            status: PROPOSAL_PENDING
        });
        self.activeProposalId[chainId_] = id;
    }

    function _requireObservedAfterReceipt(
        CcipAttestationState storage self,
        uint256 chainId_,
        uint64 remoteTimestamp_
    ) private view {
        uint64 receiptAt = self.lastValueMovingReceiptAt[chainId_];
        if (remoteTimestamp_ <= receiptAt) {
            revert ObservationPredatesValueMovingReceipt(chainId_, remoteTimestamp_, receiptAt);
        }
    }

    /// @dev True when `v_` lies strictly outside `+-ATTESTATION_ANCHOR_BAND_BPS` of `anchor_`. `>` reverts and
    ///      `==` passes, the same convention as `BigChangeExceeded`. `anchor_ == 0` is outside for every
    ///      non-zero `v_`.
    function _outsideAnchorBand(uint256 v_, uint256 anchor_) private pure returns (bool) {
        uint256 d = v_ > anchor_ ? v_ - anchor_ : anchor_ - v_;
        return d * 10_000 > anchor_ * CrosschainConstants.ATTESTATION_ANCHOR_BAND_BPS;
    }

    function approve(
        CcipAttestationState storage self,
        mapping(uint256 => uint64) storage versions_,
        mapping(uint256 => uint256) storage settled_,
        uint256 id_,
        uint256 stalenessMax_,
        uint256 bigChangeBps_,
        uint256 minUpdateInterval_
    ) public returns (uint256 chainId, uint256 balance) {
        CcipBalanceProposal storage p = self.proposals[id_];
        chainId = p.chainId;
        if (p.status != PROPOSAL_PENDING || self.activeProposalId[chainId] != id_) revert ProposalNotActive(id_);
        if (block.timestamp > p.expiry) revert ProposalExpired(id_);
        if (block.timestamp - p.remoteTimestamp > stalenessMax_) revert ObservationStale(chainId);
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
        if (p.accountingEpoch != self.accountingEpoch[chainId]) revert ProposalEpochChanged(chainId);
        uint64 current = versions_[chainId];
        if (p.stateVersion != current) revert ProposalVersionMismatch(current, p.stateVersion);
        _requireObservedAfterReceipt(self, chainId, p.remoteTimestamp);
        uint256 old = settled_[chainId];
        if (old == 0) {
            // `bigChangeBps_` is a purely RELATIVE bound, so at a zero baseline it constrains nothing and
            // a single approval could write an arbitrary NAV (audit
            // `no_cumulative_bound_on_attested_balance_ratchet`). The window is not just the pre-first-
            // attestation state: a full recall debits the bucket back to zero
            // (`CcipCrosschainExecutor.requestAssetsFromDispatcher`, then `applyReturnDebit` from the
            // RETURN_TRANSFER handler), re-opening it.
            //
            // A zero bucket has no on-chain anchor to bound against, so attestation — two keys the threat
            // model treats as Untrusted — must not be able to leave it. The two paths that legitimately
            // do are both stronger: an authenticated TRANSFER_SETTLED credits `settled` directly, and the
            // timelocked, guardian-vetoable `forceSetSettled` below overwrites it. A zero-to-zero
            // approval stays allowed: it carries no value; the only write is the proposal's
            // `remoteTimestamp` into `lastApprovedObservedAt` (plus the approval bookkeeping below;
            // `approveWithRepair`, the executor's `approveBalance` body, also, if `frontierRepairPending` is
            // set, clears it and lifts `chainBlocked`).
            //
            // The baseline is the ANCHOR, not the bucket (IL-8606 / TP-M-28): a full recall of a bucket
            // whose remote side kept earning leaves a dispatcher-authenticated residual above the dust
            // bound, and `applyReturnDebit` then keeps the anchor at that residual while `settled` is 0
            // (a later authenticated return at `settled == 0` may lower it, IL-9134).
            // From such a state a positive attestation is bounded by the anchor band alone (the relative
            // check is meaningless at a zero baseline), so the residual can be priced without the
            // timelocked force-set. With no anchor the zero-baseline rule above is unchanged.
            if (p.balance != 0) {
                uint256 anchor = self.anchorPrincipal[chainId];
                if (anchor == 0) revert UnanchoredAttestation(chainId, p.balance);
                uint256 anchorDiff = p.balance > anchor ? p.balance - anchor : anchor - p.balance;
                if (anchorDiff * 10_000 > anchor * CrosschainConstants.ATTESTATION_ANCHOR_BAND_BPS) {
                    revert AttestationOutsideAnchorBand(
                        chainId,
                        anchor,
                        p.balance,
                        CrosschainConstants.ATTESTATION_ANCHOR_BAND_BPS
                    );
                }
            }
        } else if (p.balance == 0 && old <= CrosschainConstants.ATTESTATION_ZERO_DUST_SD) {
            // IL-8499 / IL-8424 #6: rounding dust left by a full recall (dispatcher already reports 0)
            // could otherwise only be cleared by the timelocked force-set, because dust -> 0 is a 100%
            // relative change. Exactly-zero, at or below an absolute bound: skip the relative and band
            // checks and reset the anchor with the bucket (they reach zero together). Cannot raise NAV.
            self.anchorPrincipal[chainId] = 0;
            self.netPrincipal[chainId] = 0;
            emit AttestationAnchorUpdated(chainId, 0);
            emit AttestationNetPrincipalUpdated(chainId, 0);
        } else {
            // Anchored band (IL-7967, audit `no_cumulative_bound_on_attested_balance_ratchet`): the
            // relative `BigChangeExceeded` check bounds one step, not the number of steps; `n` compliant
            // approvals compound to `(1 ± bigChangeBps_/10_000)^n`. The band is checked AFTER the relative
            // check so that revert keeps firing first whenever the relative check applies.
            //
            // IL-8737: the relative check applies only while `old` is itself a baseline, i.e. inside the
            // anchor band (outside the band on either side skips it; only below is reachable). `old` can sit BELOW the band after an anchor credit on a `(settled 0, anchor R)`
            // pair with `net > 0` (an approved loss): the credit cap `min(R, net) + c` gives `(c, min(R, net) + c)`.
            // `old` is below the band iff `c < 4 * min(R, net)`; the `BigChangeExceeded` window around `old` and
            // the band are disjoint (the pre-fix freeze) iff `c * (1 + bigChangeBps_ / 10_000) < 0.8 * (min(R, net)
            // + c)`, e.g. `c < 2 * min(R, net)` at 20%. Then NO value would be approvable (NAV frozen
            // at `BALANCE_STALENESS_MAX` until a recall of the whole bucket or a force-set). Such an `old` is
            // not a baseline, exactly like `old == 0` (IL-8606), so the band alone bounds the approval. The
            // band still caps a single approval at `1.2 * anchor`, and the anchor only grows from
            // authenticated credits (IL-8578), so no attester gains more than the zero-baseline path already
            // gives. After the first band approval the pair is band-legal again and the relative check
            // returns. `principal == 0` keeps the relative check (it cannot occur with `old != 0`).
            //
            // The earlier induction ("the pair is band-legal after every write, so `settled` itself is an
            // approvable value") held for every write except an anchor CREDIT on a `(0, R)` pair: the credit
            // floor keeps `settledAfter <= 1.2 * anchor` but nothing keeps `settledAfter >= 0.8 * anchor`.
            // Approve and `forceSetSettled` leave the pair in the band, and the clamped debit preserves band-
            // legality of an in-band pair. Once such a credit puts the pair below the band it stays there
            // (further credits, partial debits) until the next approval.
            //
            // The debit clamp is what makes the band self-consistent on the recall path. `Ceil` rounding in
            // the pro-rata debit shrinks the anchor faster than the bucket, so an un-clamped pair could land
            // outside the band and the two windows would be disjoint (a permanent attestation freeze,
            // reachable by an ordinary recall that returns a few SD units short). The clamp re-anchors so
            // that the post-debit pair satisfies the band, hence `settledAfter` itself is an approvable
            // value. Swept over the reachable `(principal, settled, debit)` space in
            // `audit/IL-7942/IL-7967/anchor_band_sweep.py`. The clamp only ever raises the anchor to the
            // MINIMUM band-restoring value, which that induction bounds by the pre-debit principal, so it
            // cannot be used to walk the anchor upward.
            uint256 principal = self.anchorPrincipal[chainId];
            if (principal == 0 || !_outsideAnchorBand(old, principal)) {
                uint256 diff = p.balance > old ? p.balance - old : old - p.balance;
                if (diff * 10_000 > old * bigChangeBps_) {
                    revert BigChangeExceeded(old, p.balance, bigChangeBps_);
                }
            }
            if (_outsideAnchorBand(p.balance, principal)) {
                revert AttestationOutsideAnchorBand(
                    chainId,
                    principal,
                    p.balance,
                    CrosschainConstants.ATTESTATION_ANCHOR_BAND_BPS
                );
            }
        }
        uint64 previous = self.lastApprovalAt[chainId];
        if (previous != 0 && block.timestamp - previous < minUpdateInterval_) {
            revert MinUpdateIntervalNotMet(previous, block.timestamp, minUpdateInterval_);
        }
        balance = p.balance;
        settled_[chainId] = balance;
        self.lastApprovedObservedAt[chainId] = p.remoteTimestamp;
        self.lastApprovalAt[chainId] = uint64(block.timestamp);
        p.status = PROPOSAL_APPROVED;
        delete self.activeProposalId[chainId];
    }

    function reject(CcipAttestationState storage self, uint256 id_) public returns (uint256 chainId) {
        CcipBalanceProposal storage p = self.proposals[id_];
        chainId = p.chainId;
        if (p.status != PROPOSAL_PENDING || self.activeProposalId[chainId] != id_) revert ProposalNotActive(id_);
        p.status = PROPOSAL_REJECTED;
        delete self.activeProposalId[chainId];
    }

    /// @dev `rejectBalanceAndBlock` body (EIP-170): reject the proposal and block its chain.
    function rejectAndBlock(
        CcipAttestationState storage self,
        mapping(uint256 => bool) storage chainBlocked_,
        mapping(uint256 => bool) storage frontierRepairPending_,
        uint256 id_
    ) public {
        uint256 chainId = reject(self, id_);
        chainBlocked_[chainId] = true;
        // Discard any pending frontier-repair latch — it belongs to the block that armed it, and leaving it
        // set would let the approver lift THIS block with one more propose/approve round, bypassing the
        // timelocked unblock (audit `stale_frontier_repair_flag_lifts_unrelated_fail_closed_chain_block`,
        // filed against Stargate). The repair's exit is then the timelocked FORCE_SET_SETTLED rescue.
        frontierRepairPending_[chainId] = false;
        emit BalanceRejectedAndBlocked(id_, chainId);
    }

    /// @dev Timelocked settled-balance overwrite that also lifts a NAV block — the counterpart
    ///      `rejectBalanceAndBlock` never had on this transport (audit
    ///      `missing_unblock_counterpart_permanent_fail_closed_nav`). `chainBlocked` was cleared in exactly
    ///      one place, `CcipCrosschainExecutor.approveBalance`, and only under `frontierRepairPending`,
    ///      which only the `ADVANCE_FRONTIER` chain rescue ever sets. A chain blocked by the circuit breaker was
    ///      therefore unreachable by any number of honest approvals, and since `balanceByChain` reverts
    ///      `ChainBlocked`, `totalAssets()` reverted with it and froze the WHOLE vault — deposits and
    ///      exits alike. The only escape was to misuse the frontier repair, which permanently discards a
    ///      legitimate remote `stateVersion`.
    ///
    ///      Deliberately NOT fixed by making `approve` clear the block: Stargate behaves the same way on
    ///      purpose, and the role that tripped the breaker should not be able to lift it by itself. What
    ///      was actually missing is this rescue, which Stargate already had as
    ///      `StargateExecutorAccountingLib.forceSetSettled`. Guards mirror it: no in-flight record may be
    ///      outstanding, or the overwrite would race a credit that is still on the wire.
    /// @dev `observedStateVersion_` is the dispatcher `stateVersion` at which `newSettledSD_` was read, and it
    ///      must equal the acknowledged frontier (`lastRemoteStateVersion`) at execute time (IL-8294) — the
    ///      binding `approve` puts on an attestation and the port of Stargate's IL-8264 fix. The in-flight
    ///      guards below are not enough on their own: `cancelPendingReturn` clears `activeReturn` while the
    ///      dispatcher may already have debited the recall and dispatched its `RETURN_TRANSFER`. From then
    ///      until the executor receives it, the dispatcher's `accountedBalance()` excludes the recalled amount
    ///      (it counts only responses still in its queue), so an overwrite read in that window would be
    ///      debited a second time, together with the anchor, by the late return. With the binding, a response
    ///      still queued or on the wire carries a version above the frontier, so the version must already be
    ///      the frontier when the rescue is scheduled (an observation above it is refused at schedule, as it
    ///      could match at execute only after such a response landed), and any debit that lands after the
    ///      overwrite carries a higher version than the observation, so the observation cannot have included it.
    ///      Not covered: an `ADVANCE_FRONTIER` past a value-moving response that is still deliverable. Two
    ///      handlers apply their delta whenever the response lands, whatever its version:
    ///      - `RETURN_TRANSFER` debits `settled` (by the dispatcher-declared sent amount) and the anchor
    ///        (`applyReturnDebit`), so a force-set that
    ///        already excluded the returned amount is debited again (NAV understated);
    ///      - a `TRANSFER_SETTLED` for an outbound force-resolved without its credit (`creditToSettled` false)
    ///        is credited by `CcipExecutorTransferLib._applyLateCredit` only when its version is above this
    ///        force-set's (`repairSettleVersion`, IL-8619); at or below it the force-set already priced it and
    ///        the credit is skipped.
    ///      Advance the frontier only past a response the dispatcher can no longer deliver (dropped by
    ///      `scheduleSkipStuckResponse`, which puts its tokens back into `trackedIdle`). Flush a response still
    ///      in the dispatcher queue, and manually execute one that FAILED on the destination OffRamp.
    ///      The executor's `ADVANCE_FRONTIER` branch also clears the chain's cancelled-recall clock
    ///      (IL-8590): a dropped return's tokens are back in `trackedIdle` and `settled` was never debited,
    ///      so that clock guards nothing; the chain stays blocked and the repair latch forces a fresh
    ///      approved attestation at the new frontier before NAV reopens. The clear waits for the reset guard:
    ///      while a cancelled recall's request may still be honoured the advance keeps the clock (it never
    ///      reverts on it), and the executor's force-set branch reverts `CancelledRecallNotExpired` after this
    ///      call.
    /// @dev Also not covered: any versioned response that lands between schedule and execute makes the execute
    ///      revert. Since IL-8257 only the value-moving `TRANSFER_SETTLED` / `RETURN_TRANSFER` responses are
    ///      versioned; value-neutral traffic (`requestRemoteBalance`, command acknowledgements, retries and
    ///      cancels) no longer bumps the version and cannot void the rescue. The manager can still trigger
    ///      value-moving traffic (outbound transfers, recalls) at will, so pause the vault for the rescue
    ///      window.
    /// @dev This rescue is also the designed exit for a post-recall residue whose true value sits below the
    ///      attestation band because it carries an unrecognised remote loss (IL-8585).
    /// @dev IL-8646 / TP-L-18: `observedRemoteTimestamp_` (committed and validated at schedule time) becomes
    ///      `lastApprovedObservedAt`. NAV is stale right after execute exactly when
    ///      `executeTime - observedRemoteTimestamp > BALANCE_STALENESS_MAX` (`ObservationStale`): an observation
    ///      older than `BALANCE_STALENESS_MAX - RESCUE_DELAY` at schedule is sufficient but not necessary (a late
    ///      execution also ages it), and every force-set is stale when `RESCUE_DELAY >= BALANCE_STALENESS_MAX`.
    ///      An ordinary attestation restores freshness; the next ordinary observation must be at least this
    ///      timestamp (IL-8648).
    /// @dev IL-8648 R1: the force-set must not move that clock backwards either. Unless `allowOlderThanApproved_`
    ///      (the `FORCE_SET_SETTLED_UNCHECKED` kind, chosen in the schedule-time commitment) it reverts
    ///      `ForceSetOlderThanApproved` when the committed time is older than `lastApprovedObservedAt` (equal
    ///      passes; a chain with no approval yet has 0 and passes). `arg_` is the packed rescue word
    ///      `(observedStateVersion << 192) | (observedRemoteTimestamp << 128) | newSettledLD`; the library decodes
    ///      version and time itself to keep the argument count (stack depth) unchanged.
    function forceSetSettled(
        CcipAttestationState storage self,
        mapping(uint256 => uint256) storage settled_,
        mapping(uint256 => bool) storage chainBlocked_,
        mapping(uint256 => bool) storage frontierRepairPending_,
        mapping(uint256 => uint8) storage pendingTransferCount_,
        mapping(uint256 => bytes32) storage activeReturn_,
        mapping(uint256 => uint64) storage lastRemoteStateVersion_,
        uint256 chainId_,
        uint256 newSettledSD_,
        uint256 arg_,
        bool allowOlderThanApproved_
    ) public {
        uint64 acknowledged = lastRemoteStateVersion_[chainId_];
        if (uint64(arg_ >> 192) != acknowledged) {
            revert ForceSetStateVersionMismatch(chainId_, acknowledged, uint64(arg_ >> 192));
        }
        uint256 pending = pendingTransferCount_[chainId_];
        if (pending != 0) revert PendingTransfersExist(chainId_, pending);
        if (activeReturn_[chainId_] != bytes32(0)) revert PendingTransfersExist(chainId_, 1);
        // IL-8648 R1: the ordinary approve never moves the NAV clock backwards; neither does a force-set,
        // unless it was scheduled as UNCHECKED (the choice is in the commitment, so the guardian saw it).
        if (!allowOlderThanApproved_ && self.lastApprovedObservedAt[chainId_] > uint64(arg_ >> 128)) {
            revert ForceSetOlderThanApproved(chainId_, uint64(arg_ >> 128), self.lastApprovedObservedAt[chainId_]);
        }
        settled_[chainId_] = newSettledSD_;
        // Rescue overwrite is the authoritative rebase (IL-7967): the timelocked, guardian-vetoable
        // admin has confirmed the true remote value, so the accounting anchor is reset to match it —
        // this is the only place a cumulative yield/loss beyond the band is recognised.
        self.anchorPrincipal[chainId_] = newSettledSD_;
        self.netPrincipal[chainId_] = newSettledSD_;
        emit AttestationAnchorRebased(chainId_, newSettledSD_);
        emit AttestationNetPrincipalUpdated(chainId_, newSettledSD_);
        chainBlocked_[chainId_] = false;
        // Clear the repair flag too: leaving it armed would let the NEXT ordinary approval lift a future,
        // unrelated block for free.
        frontierRepairPending_[chainId_] = false;
        // IL-8646 / TP-L-18: the NAV freshness marker is the REMOTE observation time committed in the schedule-time
        // hash, never the execute time (the figure already aged `RESCUE_DELAY` in the queue). The cadence limiter
        // keeps the local clock: it treats this as the chain's most recent approval.
        self.lastApprovedObservedAt[chainId_] = uint64(arg_ >> 128);
        self.lastApprovalAt[chainId_] = uint64(block.timestamp);
        ++self.repairSettleSeq[chainId_];
        self.repairSettleVersion[chainId_] = uint64(arg_ >> 192);
        bumpEpochValueMoving(self, chainId_);
        emit SettledBalanceForceSet(chainId_, newSettledSD_);
    }

    /// @dev Schedule-time gates of a `FORCE_SET_SETTLED` / `FORCE_SET_SETTLED_UNCHECKED` argument
    ///      `(observedStateVersion << 192) | (observedRemoteTimestamp << 128) | newSettledLD`. Body of the
    ///      executor's `scheduleChainRescue` branch, moved here for EIP-170 headroom. `rate_` is the executor's
    ///      `DECIMAL_CONVERSION_RATE`: the low 128 bits are a balance in local asset decimals and must be a
    ///      multiple of it, else the schedule reverts `CcipDecimalsLib.AmountHasDust` (IL-9025). Without the
    ///      check a dusty value would only fail at execute, after `RESCUE_DELAY` had been spent.
    function checkForceSetSchedule(
        CcipAttestationState storage self,
        mapping(uint256 => uint64) storage lastRemoteStateVersion_,
        uint256 chainId_,
        uint256 arg_,
        uint256 balanceStalenessMax_,
        uint256 rate_
    ) public view {
        // The observation must already be at the frontier: one behind it can never match at execute, and one
        // above it could only match after a queued response (e.g. a `RETURN_TRANSFER` the observation
        // already excludes) lands during the delay, which would count its tokens a second time. This also
        // catches an unpacked plain balance (version 0) once the chain has acknowledged any response.
        uint64 acknowledged = lastRemoteStateVersion_[chainId_];
        if (uint64(arg_ >> 192) != acknowledged) {
            revert ForceSetStateVersionMismatch(chainId_, acknowledged, uint64(arg_ >> 192));
        }
        // IL-8646 / TP-L-18: the committed remote observation time must be a plausible, still-fresh one.
        uint64 observedAt = uint64(arg_ >> 128);
        if (observedAt == 0 || observedAt > block.timestamp || block.timestamp - observedAt > balanceStalenessMax_) {
            revert ObservationStale(chainId_);
        }
        // IL-8604 R1: version equality binds the version, not the read; a read taken before a queued
        // RETURN_TRANSFER was flushed shares its version yet still counts the returned tokens.
        uint64 receiptAt = self.lastValueMovingReceiptAt[chainId_];
        if (observedAt <= receiptAt) revert ObservationPredatesValueMovingReceipt(chainId_, observedAt, receiptAt);
        // IL-9025: the settled balance is booked in shared decimals, so the local-decimals value must convert
        // exactly (same rule as `CcipDecimalsLib.toSDExact`, inline so the library gains no link reference).
        if (uint128(arg_) % rate_ != 0) revert CcipDecimalsLib.AmountHasDust(uint128(arg_));
    }

    /// @dev Body of the executor's `RETURN_TRANSFER` debit (moved here so the debit and the accounting
    ///      anchor pro-rata reduction land together, at zero extra executor bytes — IL-7967). `sentSD_` is
    ///      the peer-authenticated amount the dispatcher DECLARED it sent (pre transport fee), not the
    ///      amount that arrived (IL-8497): the fee is part of what left the remote position, so debiting
    ///      the received amount would strand it in `settled` as phantom value that no zero re-mark can
    ///      clear. The debit is bounded by `min(maxAccounted_, settled)` (alarm on any excess).
    ///      Same rule as Stargate's `_applyReturnDebit`. Inbound handler: clamp, never revert.
    ///      `remoteBalanceSD_` is the dispatcher's authenticated post-debit balance carried by the
    ///      `RETURN_TRANSFER`; it only matters when the debit empties the bucket or the bucket is already
    ///      empty (see "Residual anchor" below).
    ///      Residual anchor: (1) a debit that empties the bucket keeps a non-dust `remoteBalanceSD_` as the
    ///      anchor (IL-8606). (2) A later authenticated return at `settled == 0` (for example a second recall
    ///      opened after the first one was cancelled) recomputes the anchor from the reported balance, only
    ///      downwards and to zero at or below dust, so a stale residual cannot anchor a phantom attestation
    ///      (IL-9134).
    ///      The pro-rata anchor debit assumes the recalled amount holds principal and unrecognised P&L in the
    ///      bucket's proportions. The dispatcher pays a recall out of `trackedIdle` only, so a return shorter
    ///      than the attested bucket leaves a residue that still carries the whole unrecognised remote loss;
    ///      once that loss puts the true value below the band floor and the residue is above
    ///      `ATTESTATION_ZERO_DUST_SD`, it cannot be attested down. The exit is `rejectBalanceAndBlock` plus
    ///      `forceSetSettled` (IL-8585 / TP-M-07); operators attest known losses BEFORE recalling.
    /// @return debit The amount actually debited from `settled_[chainId_]`.
    function applyReturnDebit(
        CcipAttestationState storage self,
        mapping(uint256 => uint256) storage settled_,
        uint256 chainId_,
        bytes32 operationId_,
        uint256 sentSD_,
        uint256 maxAccounted_,
        uint256 remoteBalanceSD_
    ) public returns (uint256 debit) {
        uint256 settled = settled_[chainId_];
        uint256 cap = maxAccounted_ < settled ? maxAccounted_ : settled;
        debit = sentSD_;
        if (debit > cap) {
            debit = cap;
            emit ReturnDebitExceededAccountingBound(chainId_, operationId_, sentSD_, cap);
        }
        settled_[chainId_] = settled - debit;
        // Accounting anchor pro-rata debit (IL-7967): a recall removes principal and unrecognised yield in
        // the proportion the settled bucket holds them, so the band headroom is preserved across a partial
        // recall and both reach zero together on a full recall — except a non-dust residual reported by the
        // dispatcher, which keeps the anchor (residual rule below). Rounds UP (Ceil) so the anchor never
        // over-states remaining principal — the conservative direction, since the band is measured against
        // it. `settled != 0` guards the `Math.mulDiv` denominator.
        if (settled != 0 && debit != 0) {
            uint256 principal = self.anchorPrincipal[chainId_];
            uint256 principalDebit = Math.mulDiv(principal, debit, settled, Math.Rounding.Ceil);
            uint256 remaining = principalDebit > principal ? 0 : principal - principalDebit;
            uint256 settledAfter = settled - debit;
            // Band consistency (IL-7967 cycle 3). Ceil shrinks the anchor faster than the bucket, so the
            // pro-rata pair can land OUTSIDE the very band `approve` enforces. The band window and the
            // relative window are then disjoint and NO approvable value exists: `lastApprovedObservedAt`
            // can never be refreshed again and `balanceByChain` fails closed on `ObservationStale`.
            // Restore the band by the MINIMUM raise — the smallest anchor for which `settledAfter` sits
            // inside it, `ceil(settledAfter * 10_000 / (10_000 + bandBps))`. NOT `settledAfter` itself:
            // that adopts an ATTESTED figure as principal and lets a 1-unit recall from the top of the band
            // carry the anchor to ~1.2x, compounding into the ratchet this ticket closes. The minimum
            // raise cannot: the pre-debit pair is band-legal, so `settledAfter <= settled <=
            // principal * (10_000 + bandBps) / 10_000` and the raised value is <= the pre-debit
            // `principal` — the anchor is non-increasing under debits (the residual rule below is capped to
            // keep it so). It also subsumes a floor at 1: with `remaining == 0` and `settledAfter != 0` the
            // raise yields at least 1. Clamp, never revert.
            uint256 bandBps = CrosschainConstants.ATTESTATION_ANCHOR_BAND_BPS;
            if (settledAfter > remaining && (settledAfter - remaining) * 10_000 > remaining * bandBps) {
                remaining = Math.mulDiv(settledAfter, 10_000, 10_000 + bandBps, Math.Rounding.Ceil);
            }
            // Residual anchor (IL-8606 / TP-M-28): a recall that empties the bucket while the dispatcher's
            // authenticated post-debit balance still holds more than dust (yield earned after the last
            // attestation) keeps that residual as the anchor, so an ordinary attestation can price it inside
            // the band instead of leaving it orphaned behind a zero baseline. `settled` itself is NOT
            // credited: the residual enters NAV only once attested.
            if (settledAfter == 0 && remoteBalanceSD_ > CrosschainConstants.ATTESTATION_ZERO_DUST_SD) {
                // Capped at the pre-debit anchor: an honest residual (yield since the last attestation) never
                // exceeds it, and the cap keeps the anchor non-increasing under debits even if the reported
                // figure was inflated (e.g. a spot-manipulable allowlisted vault on a permissionless delivery).
                remaining = remoteBalanceSD_ < principal ? remoteBalanceSD_ : principal;
            }
            self.anchorPrincipal[chainId_] = remaining;
            emit AttestationAnchorUpdated(chainId_, remaining);
        } else if (settled == 0 && sentSD_ != 0) {
            // Later return at `settled == 0` (IL-9134): a return authenticated after the bucket was already
            // emptied (e.g. a second recall opened after the first one was cancelled) has nothing to debit,
            // but its `remoteBalanceSD_` is still the dispatcher's authenticated post-debit balance. Follow
            // it: the anchor becomes that balance (zero when at or below dust), capped at the current anchor
            // so it only ever moves down.
            uint256 principalAtZero = self.anchorPrincipal[chainId_];
            uint256 anchorAtZero = remoteBalanceSD_ > CrosschainConstants.ATTESTATION_ZERO_DUST_SD
                ? (remoteBalanceSD_ < principalAtZero ? remoteBalanceSD_ : principalAtZero)
                : 0;
            self.anchorPrincipal[chainId_] = anchorAtZero;
            emit AttestationAnchorUpdated(chainId_, anchorAtZero);
        }
        // Net principal (IL-8578 / TP-H-02): debited by the amount the dispatcher declared it sent back
        // (`sentSD_`, authenticated by the transport), floored at zero, NOT by the settled delta. The
        // attester pair can lower `settled` while a recall is in flight, so the settled delta can be smaller
        // than the real return and would leave phantom units in `netPrincipal` that inflate the credit cap
        // round after round. Pro-rata anchor debit and band clamp above are unchanged.
        if (sentSD_ != 0) {
            uint256 net = self.netPrincipal[chainId_];
            net = sentSD_ > net ? 0 : net - sentSD_;
            self.netPrincipal[chainId_] = net;
            emit AttestationNetPrincipalUpdated(chainId_, net);
        }
    }

    /// @notice Credit the accounting anchor for a peer-authenticated (or timelocked force-resolved) credit
    ///         that was ALREADY added to `settled_[chainId_]` (IL-8578 / TP-H-02). Raises `netPrincipal` by
    ///         `credited` and sets the anchor to `max(min(anchor + credited, net), floor)` (it may lower
    ///         it), where `floor = ceil(settledAfter * 10_000 / (10_000 + bandBps))`.
    /// @dev The cap closes the recall / re-supply ratchet: a pro-rata recall debit leaves the anchor above
    ///      the net principal remaining whenever `settled` carries unrecognised yield, so a full-value
    ///      anchor credit on re-supply would grow band headroom with no new capital. After any round trip
    ///      the anchor is at most `max(netPrincipal, the pre-recall anchor)`, up to one shared-decimal
    ///      unit of `Ceil` rounding per credit (a cycle costs two bridge round trips and an attestation
    ///      to gain one unit, so it is not economically exploitable). The floor term keeps the
    ///      pair below the band ceiling (`settled <= 1.2 * anchor`): an honest yield residue left
    ///      remote after a full recall (net 0), followed by a small top-up, must stay attestable. The floor
    ///      is the same minimum raise `applyReturnDebit` uses, so it cannot be used to walk the anchor up.
    ///      IL-8737: the floor only bounds `settledAfter <= 1.2 * anchor`; nothing bounds it from below. On a
    ///      `(settled 0, anchor R, net N > 0)` pair a top-up `c` gives `(c, min(R, N) + c)`, which is below the
    ///      band iff `c < 4 * min(R, N)`; the windows were disjoint (pre-fix freeze) iff
    ///      `c * (1 + bigChangeBps / 10_000) < 0.8 * (min(R, N) + c)`, e.g. `c < 2 * min(R, N)` at 20%.
    ///      `approve` then treats that `settled` as no baseline (band alone, like
    ///      zero, IL-8606), so an approvable value always exists.
    function creditAnchor(
        CcipAttestationState storage self,
        mapping(uint256 => uint256) storage settled_,
        uint256 chainId_,
        uint256 credited_
    ) public {
        uint256 net = self.netPrincipal[chainId_] + credited_;
        self.netPrincipal[chainId_] = net;
        uint256 anchor = self.anchorPrincipal[chainId_] + credited_;
        if (anchor > net) anchor = net;
        uint256 floor_ = Math.mulDiv(
            settled_[chainId_],
            10_000,
            10_000 + CrosschainConstants.ATTESTATION_ANCHOR_BAND_BPS,
            Math.Rounding.Ceil
        );
        if (anchor < floor_) anchor = floor_;
        self.anchorPrincipal[chainId_] = anchor;
        emit AttestationAnchorUpdated(chainId_, anchor);
        emit AttestationNetPrincipalUpdated(chainId_, net);
    }

    /// @dev `bumpEpoch` for a value-moving receipt: also records the local time so observations taken before it
    ///      are refused by `propose` / `approve` (IL-8604 / IL-8584) and by `checkForceSetSchedule` (IL-8604 R1).
    function bumpEpochValueMoving(CcipAttestationState storage self, uint256 chainId_) public {
        self.lastValueMovingReceiptAt[chainId_] = uint64(block.timestamp);
        bumpEpoch(self, chainId_);
    }

    function bumpEpoch(CcipAttestationState storage self, uint256 chainId_) public {
        uint64 newEpoch;
        unchecked {
            newEpoch = ++self.accountingEpoch[chainId_];
        }
        uint256 pid = self.activeProposalId[chainId_];
        if (pid != 0) {
            self.proposals[pid].status = PROPOSAL_SUPERSEDED;
            delete self.activeProposalId[chainId_];
            emit ProposalInvalidated(chainId_, pid, newEpoch);
        }
    }

    /// @dev `approveBalance` body (EIP-170): IL-8614 open-transfer guard, `approve`, then the frontier-repair latch
    ///      clear (lifts the block, records the IL-8619 repair write) and the approval events.
    function approveWithRepair(
        CcipAttestationState storage self,
        mapping(uint256 => uint64) storage versions_,
        mapping(uint256 => uint256) storage settled_,
        mapping(uint256 => bool) storage frontierRepairPending_,
        mapping(uint256 => bool) storage chainBlocked_,
        mapping(uint256 => uint256) storage outboundInFlight_,
        uint256 id_,
        uint256 stalenessMax_,
        uint256 bigChangeBps_,
        uint256 minUpdateInterval_
    ) public {
        // IL-8614 / TP-M-36: a frontier repair can skip a lost TRANSFER_SETTLED while the outbound record still
        // holds the amount in `outboundInFlight`; approving now would write a `settled` that already contains
        // the delivered amount on top of it (S + 2A). Refuse until the record is closed. Checked before
        // `approve` writes `settled`; an unknown proposal id reads chain 0, which never has the latch set.
        uint256 repairChainId = self.proposals[id_].chainId;
        if (frontierRepairPending_[repairChainId] && outboundInFlight_[repairChainId] != 0) {
            revert FrontierRepairBlockedByOpenTransfers(repairChainId, outboundInFlight_[repairChainId]);
        }
        (uint256 chainId, uint256 balance) = approve(
            self,
            versions_,
            settled_,
            id_,
            stalenessMax_,
            bigChangeBps_,
            minUpdateInterval_
        );
        if (frontierRepairPending_[chainId]) {
            // IL-8619: only the latch-clearing approval can contain a delivered amount whose settlement is still
            // deliverable (its version is not above the approved one); a routine version-bound approval never does.
            ++self.repairSettleSeq[chainId];
            self.repairSettleVersion[chainId] = versions_[chainId];
            frontierRepairPending_[chainId] = false;
            chainBlocked_[chainId] = false;
            emit ChainUnblockedByApproval(chainId, id_);
        }
        emit BalanceApproved(id_, chainId, balance);
    }
}

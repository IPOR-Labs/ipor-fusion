// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CcipAttestationState, CcipExecutorAttestationLib} from "./CcipExecutorAttestationLib.sol";
import {CrosschainConstants} from "../../lib/CrosschainConstants.sol";

enum ReturnStatus {
    NONE,
    REQUESTED,
    FINALIZED,
    REJECTED,
    CANCELLED
}

/// @notice An outbound (send) transfer awaiting its destination settlement receipt.
/// @dev Lives only in the executor's `outboundTransfers` storage mapping: it is never ABI-encoded into a CCIP
///      message or an event payload, so adding `minDeliveredSD` (IL-8581) does not touch any wire format. The
///      mapping is keyed by `operationId`, so the extra slot cannot shift another variable's layout.
struct Outbound {
    uint256 chainId;
    uint256 amount;
    uint64 createdAt;
    bool settled;
    bool forceResolved;
    bool remoteCreditAccounted;
    uint8 stalenessSlot;
    /// @dev IL-8619: the chain's `repairSettleSeq` at force-resolve time; a later value means the frontier-repair
    ///      latch-clearing approval (or a force-set) priced the chain after the resolve. A late settlement is then
    ///      skipped only if its version is not above that write's (`repairSettleVersion`).
    uint64 resolveRepairSeq;
    /// @dev Application-level floor on the tokens the destination must receive, shared decimals; 0 = no floor.
    uint256 minDeliveredSD;
}

/// @notice A recall awaiting the token-bearing return leg.
struct PendingReturn {
    uint256 chainId;
    uint256 requested;
    uint256 maxAccounted;
    uint256 minReturn;
    uint64 createdAt;
    ReturnStatus status;
}

/// @title CcipExecutorTransferLib
/// @notice In-flight transfer bookkeeping for `CcipCrosschainExecutor`: the per-chain staleness pool, recall
///         opening and cancellation with the cancelled-recall clock reset, the `TRANSFER_SETTLED` body, the
///         fail-closed per-chain NAV component (and the unchecked total), the timelocked force-resolve body and
///         the `claimAsset` payout.
/// @dev Extracted into an external linked library purely to keep the executor under the EIP-170 runtime
///      limit — the same technique the Stargate executor uses for its accounting/attestation engines.
///      Every function operates on the executor's own storage through `mapping ... storage` parameters
///      (delegatecall), so behaviour and storage layout are unchanged; only the code location moves.
///      Access control stays on the executor; these are the post-auth bodies.
/// @author IPOR Labs
library CcipExecutorTransferLib {
    error TransferStale(uint256 chainId, uint256 createdAt);
    error ChainBlocked(uint256 chainId);
    error ObservationStale(uint256 chainId);
    error PendingTransferCapReached(uint256 chainId, uint256 maximum);
    error ForceResolveWrongState(bytes32 operationId);

    error NoActiveReturn(uint256 chainId);
    error ReturnNotStale(uint256 chainId, uint256 createdAt);
    error CancelledRecallCapReached(uint256 chainId, uint256 maximum);
    /// @notice Mirror of the executor's error (raised here by `openReturn`).
    error ActiveReturnExists(uint256 chainId, bytes32 operationId);
    /// @notice Mirror of the executor's error (raised here by `openReturn`).
    error ZeroAccountedReturn(uint256 chainId);
    /// @notice Mirror of the executor's error (raised here by `openReturn`).
    error InvalidMinimumReturn(uint256 minimum, uint256 maximum);
    /// @notice Thrown when `FORCE_SET_SETTLED` (either kind) is executed while a cancelled recall's
    ///         `RETURN_REQUEST` may still be honoured by the dispatcher (IL-8590). `ADVANCE_FRONTIER` never
    ///         reverts on it: it advances and keeps the cancelled-recall clock instead.
    /// @param chainId The chain the rescue targets.
    /// @param refusedUntil Last timestamp (inclusive) at which the rescue is still refused; it succeeds one second
    ///        later.
    error CancelledRecallNotExpired(uint256 chainId, uint256 refusedUntil);

    /// @notice Mirror of the executor's event, so the delegatecalled log is indistinguishable.
    event ReturnCancelled(uint256 chainId, bytes32 operationId);
    /// @notice Mirror of the executor's event, so the delegatecalled log is indistinguishable.
    event AssetClaimed(address manager, uint256 amount);

    /// @notice Mirror of the executor's event (delegatecalled log is indistinguishable).
    event AssetSettled(uint256 chainId, bytes32 operationId, uint256 received);

    /// @notice The peer reported more than this transfer ever sent. Credited `credited` (= the recorded outbound
    ///         amount) instead of `reported`. An honest CCIP token pool cannot deliver more than was sent, so this
    ///         never fires on a healthy lane: treat it as a peer-integrity incident — stop new supply to `chainId`,
    ///         verify the dispatcher's code and `accountedBalance()` on the remote chain, and if the peer is not the
    ///         audited dispatcher block the chain (`rejectBalanceAndBlock`) and repair through `FORCE_SET_SETTLED`.
    ///         Shared decimals.
    event SettledCreditClamped(uint256 chainId, bytes32 operationId, uint256 reported, uint256 credited);

    /// @notice The destination received less than the transfer sent (`receivedSD < amountSD`): a CCIP token pool
    ///         fee or haircut, or dust. The credit that arrived is still booked and the shortfall
    ///         (`amountSD - receivedSD`) is a realized NAV loss; the chain is NOT blocked. Emitted on the fresh
    ///         settle, on the late credit after a force-resolve, and on a late settle that credits nothing because
    ///         the balance was already attested (IL-8619) or already credited by a crediting force-resolve (in
    ///         those two cases no `settled` write follows). Shared decimals.
    event SettledCreditShortfall(uint256 chainId, bytes32 operationId, uint256 amountSD, uint256 receivedSD);

    /// @notice The destination received less than the `minDelivered` floor the supply call set
    ///         (`receivedSD < minDeliveredSD`). Emitted in addition to `SettledCreditShortfall`; observability
    ///         only, it neither reverts nor blocks the chain (the tokens already moved). Emitted on the same paths
    ///         as `SettledCreditShortfall`, including a late settle that credits nothing. Shared decimals.
    event SettledBelowMinDelivered(uint256 chainId, bytes32 operationId, uint256 minDeliveredSD, uint256 receivedSD);

    /// @notice A genuine late `TRANSFER_SETTLED` for a `DROP_FROM_NAV` outbound whose `stateVersion` is not above the
    ///         version of the frontier-repair latch-clearing approval (or force-set) made since the drop: that write
    ///         already read the delivered amount, so nothing was credited (IL-8619). The record is closed. A
    ///         settlement with a higher version reached the dispatcher after the write and is credited
    ///         (`AssetSettled`).
    event LateSettlementAlreadyAttested(uint256 chainId, bytes32 operationId, uint64 stateVersion);

    /// @notice Mirror of the executor's event (delegatecalled log is indistinguishable).
    event OutboundForceResolved(bytes32 operationId, uint256 chainId, bool creditedToSettled);

    uint256 private constant _SLOTS = 16;

    /// @notice Record a new recall as the chain's active one (body of `requestAssetsFromDispatcher`, EIP-170).
    /// @dev Refuses while another recall is active, when nothing is accounted on the chain, and when the floor
    ///      exceeds what can be accounted. Shared decimals.
    /// @return maxAccounted `min(requestedSD_, settled)`: the most the recall may debit from `settled`.
    function openReturn(
        mapping(uint256 => bytes32) storage activeReturn_,
        mapping(bytes32 => PendingReturn) storage pendingReturns_,
        mapping(uint256 => uint256) storage settled_,
        uint256 chainId_,
        bytes32 operationId_,
        uint256 requestedSD_,
        uint256 minReturnSD_
    ) public returns (uint256 maxAccounted) {
        bytes32 currentReturn = activeReturn_[chainId_];
        if (currentReturn != bytes32(0)) revert ActiveReturnExists(chainId_, currentReturn);
        uint256 settled = settled_[chainId_];
        maxAccounted = requestedSD_ > settled ? settled : requestedSD_;
        if (maxAccounted == 0) revert ZeroAccountedReturn(chainId_);
        if (minReturnSD_ > maxAccounted) revert InvalidMinimumReturn(minReturnSD_, maxAccounted);
        pendingReturns_[operationId_] = PendingReturn({
            chainId: chainId_,
            requested: requestedSD_,
            maxAccounted: maxAccounted,
            minReturn: minReturnSD_,
            createdAt: uint64(block.timestamp),
            status: ReturnStatus.REQUESTED
        });
        activeReturn_[chainId_] = operationId_;
    }

    /// @notice Abandon the chain's active recall, freeing the request slot. Accounting-neutral: a recall
    ///         that has not been settled still has its value counted (and freshness-gated) in
    ///         `settledRemoteBalance`, and late authenticated delivery is still accepted afterwards.
    /// @dev Body lives here rather than on the executor for EIP-170 headroom.
    /// @dev Clearing `activeReturn` also clears one of `forceSetSettled`'s in-flight guards, while the
    ///      dispatcher may already have debited the recall and queued its `RETURN_TRANSFER`. That overwrite is
    ///      therefore bound to the observed dispatcher state version as well (IL-8294), which keeps it from
    ///      landing before the queued return does.
    /// @dev IL-8590: the recall's staleness clock is carried over instead of dropped. `cancelledCount_` counts
    ///      the chain's cancelled-but-unresolved recalls and `cancelledAt_` holds the OLDEST `createdAt` among
    ///      them; `balanceByChain` keeps enforcing the transfer staleness gate against it until every one is
    ///      resolved (late return, rejection) or `FORCE_SET_SETTLED` / `ADVANCE_FRONTIER` clears the chain
    ///      through `resetCancelledRecall` (each reset bumps `generation_`; the per-op `generationOf_` lets the
    ///      executor ignore a stale answer).
    /// @param latestCancelledAt_ NEWEST `createdAt` among the chain's cancelled recalls (reset-guard anchor).
    /// @param stalenessMax_ How long the recall must have been outstanding on the permissionless path; a zero
    ///        value there always refuses. Ignored on the manager path (the executor passes 0).
    /// @param requireStale_ True for the permissionless `cancelStalePendingReturn` path (staleness required, not
    ///        capped); false for the manager's `cancelPendingReturn` (no timing precondition, capped at
    ///        `MAX_CANCELLED_RECALLS_PER_CHAIN` unresolved cancelled recalls, IL-8583).
    function cancelPendingReturn(
        mapping(uint256 => bytes32) storage activeReturn_,
        mapping(bytes32 => PendingReturn) storage pendingReturns_,
        mapping(uint256 => uint32) storage cancelledCount_,
        mapping(uint256 => uint64) storage cancelledAt_,
        mapping(uint256 => uint32) storage generation_,
        mapping(bytes32 => uint32) storage generationOf_,
        mapping(uint256 => uint64) storage latestCancelledAt_,
        uint256 chainId_,
        uint256 stalenessMax_,
        bool requireStale_
    ) public {
        bytes32 operationId = activeReturn_[chainId_];
        if (operationId == bytes32(0)) revert NoActiveReturn(chainId_);
        // IL-8583: the manager path is capped so an unmetered recall -> cancel loop cannot leave an unbounded number
        // of RETURN_TRANSFER / RETURN_REJECTED responses in the dispatcher queue. The permissionless stale path is
        // deliberately NOT capped: on a dead return lane nobody could otherwise cancel the recall, and an active
        // recall makes FORCE_SET_SETTLED revert PendingTransfersExist, which would shut the timelocked exit.
        if (!requireStale_ && cancelledCount_[chainId_] >= CrosschainConstants.MAX_CANCELLED_RECALLS_PER_CHAIN) {
            revert CancelledRecallCapReached(chainId_, CrosschainConstants.MAX_CANCELLED_RECALLS_PER_CHAIN);
        }
        PendingReturn storage pending = pendingReturns_[operationId];
        if (requireStale_ && (stalenessMax_ == 0 || block.timestamp <= uint256(pending.createdAt) + stalenessMax_)) {
            revert ReturnNotStale(chainId_, pending.createdAt);
        }
        pending.status = ReturnStatus.CANCELLED;
        delete activeReturn_[chainId_];
        ++cancelledCount_[chainId_];
        // Remember which reset generation this cancel belongs to: a force-set / ADVANCE_FRONTIER reset bumps the
        // generation, and a late answer of an older generation must not decrement the newer count.
        generationOf_[operationId] = generation_[chainId_];
        uint64 oldestCancelled = cancelledAt_[chainId_];
        if (oldestCancelled == 0 || pending.createdAt < oldestCancelled) cancelledAt_[chainId_] = pending.createdAt;
        // The reset guard keys on the NEWEST cancelled recall: its request deadline is the last to pass.
        if (pending.createdAt > latestCancelledAt_[chainId_]) latestCancelledAt_[chainId_] = pending.createdAt;
        emit ReturnCancelled(chainId_, operationId);
    }

    /// @notice Drop a chain's cancelled-recall clock and start a new generation (IL-8590), behind a guard: while a
    ///         cancelled recall is unresolved the reset waits until the newest one's request deadline
    ///         (`latestCancelledAt_ + transferStalenessMax_`) plus `RECALL_DEADLINE_SKEW_MARGIN` has passed, i.e.
    ///         `block.timestamp > refusedUntil`. Past it the dispatcher rejects every cancelled request `EXPIRED`
    ///         (assuming the two chains' timestamps differ by less than the margin), so clearing the clock cannot
    ///         leave value-moving requests unpriced.
    /// @dev Body lives here rather than on the executor for EIP-170 headroom. Before the window has passed: with
    ///      `strict_` it reverts `CancelledRecallNotExpired(chainId_, refusedUntil)`; otherwise it leaves the clock
    ///      (count, both anchors, generation) untouched and returns. With no cancelled recall it always resets.
    function resetCancelledRecall(
        mapping(uint256 => uint32) storage count_,
        mapping(uint256 => uint64) storage cancelledAt_,
        mapping(uint256 => uint64) storage latestCancelledAt_,
        mapping(uint256 => uint32) storage generation_,
        uint256 chainId_,
        uint256 transferStalenessMax_,
        bool strict_
    ) public {
        if (count_[chainId_] != 0) {
            uint256 refusedUntil = uint256(latestCancelledAt_[chainId_]) + transferStalenessMax_
                + CrosschainConstants.RECALL_DEADLINE_SKEW_MARGIN;
            if (block.timestamp <= refusedUntil) {
                if (strict_) revert CancelledRecallNotExpired(chainId_, refusedUntil);
                return;
            }
        }
        delete count_[chainId_];
        delete cancelledAt_[chainId_];
        ++generation_[chainId_];
    }

    /// @dev Claim a free staleness slot for a new in-flight record, enforcing the per-chain cap.
    function armStaleness(
        mapping(uint256 => uint64[16]) storage createdAt_,
        mapping(uint256 => uint8) storage count_,
        mapping(uint256 => uint64) storage oldest_,
        uint256 chainId_
    ) public returns (uint8 slot) {
        uint8 count = count_[chainId_];
        if (count >= CrosschainConstants.MAX_PENDING_TRANSFERS_PER_CHAIN) {
            revert PendingTransferCapReached(chainId_, CrosschainConstants.MAX_PENDING_TRANSFERS_PER_CHAIN);
        }
        uint64[16] storage slots = createdAt_[chainId_];
        for (uint8 i; i < _SLOTS; ++i) {
            if (slots[i] == 0) {
                slots[i] = uint64(block.timestamp);
                count_[chainId_] = count + 1;
                uint64 oldest = oldest_[chainId_];
                if (oldest == 0 || block.timestamp < oldest) oldest_[chainId_] = uint64(block.timestamp);
                return i;
            }
        }
        revert PendingTransferCapReached(chainId_, CrosschainConstants.MAX_PENDING_TRANSFERS_PER_CHAIN);
    }

    /// @dev Release a staleness slot and recompute the per-chain oldest-unresolved marker.
    function disarmStaleness(
        mapping(uint256 => uint64[16]) storage createdAt_,
        mapping(uint256 => uint8) storage count_,
        mapping(uint256 => uint64) storage oldest_,
        uint256 chainId_,
        uint8 slot_
    ) public {
        uint64[16] storage slots = createdAt_[chainId_];
        if (slots[slot_] == 0) return;
        slots[slot_] = 0;
        --count_[chainId_];
        uint64 oldest;
        for (uint8 i; i < _SLOTS; ++i) {
            uint64 created = slots[i];
            if (created != 0 && (oldest == 0 || created < oldest)) oldest = created;
        }
        oldest_[chainId_] = oldest;
    }

    /// @dev Immutable freshness/blocking thresholds passed in by the executor.
    struct BalanceGates {
        uint256 transferStalenessMax;
        uint256 balanceStalenessMax;
    }

    /// @dev Per-chain NAV component in shared decimals: `settled + outboundInFlight`, fail-closed on a
    ///      blocked chain that still tracks value, a stale in-flight record, a stale pending recall, a stale
    ///      cancelled-but-unresolved recall (`cancelledAt_`, IL-8590), or a settled bucket without a fresh
    ///      approved observation.
    /// @dev A blocked chain with both buckets at zero returns zero instead of reverting (IL-8260): it adds
    ///      nothing to NAV, and the revert froze deposits and withdrawals for the whole vault until the
    ///      timelocked `FORCE_SET_SETTLED` rescue. A send to the chain books `outboundInFlight` and brings the
    ///      revert back. The staleness gates below still run, and the block flag itself is untouched.
    function balanceByChain(
        mapping(uint256 => bool) storage chainBlocked_,
        mapping(uint256 => uint64) storage oldestPendingAt_,
        mapping(uint256 => bytes32) storage activeReturn_,
        mapping(bytes32 => PendingReturn) storage pendingReturns_,
        mapping(uint256 => uint256) storage settled_,
        mapping(uint256 => uint256) storage outboundInFlight_,
        CcipAttestationState storage attestation_,
        uint64 cancelledAt_,
        uint256 chainId_,
        BalanceGates memory gates_
    ) public view returns (uint256) {
        uint256 settled = settled_[chainId_];
        uint256 chainTotal = settled + outboundInFlight_[chainId_];
        if (chainTotal != 0 && chainBlocked_[chainId_]) revert ChainBlocked(chainId_);
        uint64 oldest = oldestPendingAt_[chainId_];
        if (oldest != 0 && gates_.transferStalenessMax != 0 && block.timestamp > oldest + gates_.transferStalenessMax) {
            revert TransferStale(chainId_, oldest);
        }
        bytes32 returnId = activeReturn_[chainId_];
        if (returnId != bytes32(0)) {
            uint64 requestedAt = pendingReturns_[returnId].createdAt;
            if (
                gates_.transferStalenessMax != 0 && block.timestamp > uint256(requestedAt) + gates_.transferStalenessMax
            ) {
                revert TransferStale(chainId_, requestedAt);
            }
        }
        // IL-8590: a cancelled but unresolved recall keeps its clock; its return may still land.
        if (
            cancelledAt_ != 0 && gates_.transferStalenessMax != 0
                && block.timestamp > uint256(cancelledAt_) + gates_.transferStalenessMax
        ) {
            revert TransferStale(chainId_, cancelledAt_);
        }
        uint64 observedAt = attestation_.lastApprovedObservedAt[chainId_];
        if (settled != 0 && (observedAt == 0 || block.timestamp > uint256(observedAt) + gates_.balanceStalenessMax)) {
            revert ObservationStale(chainId_);
        }
        return chainTotal;
    }

    /// @dev `getBalanceUnchecked` body without idle (IL-8611; here for EIP-170): `sum(settled + outboundInFlight)` over
    ///      the listed chains, shared decimals, reverting `ChainBlocked` on a blocked chain with a nonzero total.
    function bookedRemoteTotal(
        uint256[] storage chainIds_,
        mapping(uint256 => uint256) storage settled_,
        mapping(uint256 => uint256) storage outboundInFlight_,
        mapping(uint256 => bool) storage chainBlocked_
    ) public view returns (uint256 total) {
        uint256 len = chainIds_.length;
        for (uint256 i; i < len; ++i) {
            uint256 chainId = chainIds_[i];
            uint256 chainTotal = settled_[chainId] + outboundInFlight_[chainId];
            if (chainTotal != 0 && chainBlocked_[chainId]) revert ChainBlocked(chainId);
            total += chainTotal;
        }
    }

    /// @dev Apply a timelocked terminal resolution to a permanently stuck outbound transfer. `creditToSettled_`
    ///      declares that the value provably reached the remote chain; otherwise it is dropped from NAV. Also bumps
    ///      the chain's accounting epoch (value-moving) and emits `OutboundForceResolved` (EIP-170).
    function applyForceResolveOutbound(
        mapping(bytes32 => Outbound) storage outbound_,
        mapping(uint256 => uint256) storage outboundInFlight_,
        mapping(uint256 => uint256) storage settled_,
        mapping(uint256 => uint64[16]) storage createdAt_,
        mapping(uint256 => uint8) storage count_,
        mapping(uint256 => uint64) storage oldest_,
        CcipAttestationState storage attestation_,
        bytes32 operationId_,
        bool creditToSettled_
    ) public returns (uint256 chainId) {
        Outbound storage transfer = outbound_[operationId_];
        if (transfer.createdAt == 0 || transfer.settled) revert ForceResolveWrongState(operationId_);
        transfer.settled = true;
        transfer.forceResolved = true;
        chainId = transfer.chainId;
        transfer.resolveRepairSeq = attestation_.repairSettleSeq[chainId];
        outboundInFlight_[chainId] -= transfer.amount;
        if (creditToSettled_) {
            settled_[chainId] += transfer.amount;
            // Accounting anchor credit (IL-7967): the rescue admin has confirmed, under timelock, that
            // this amount reached the remote chain — verifiably-sent value, so raise the anchor too.
            // Capped at the net principal (IL-8578 / TP-H-02) by `creditAnchor`.
            CcipExecutorAttestationLib.creditAnchor(attestation_, settled_, chainId, transfer.amount);
            transfer.remoteCreditAccounted = true;
        }
        disarmStaleness(createdAt_, count_, oldest_, chainId, transfer.stalenessSlot);
        CcipExecutorAttestationLib.bumpEpochValueMoving(attestation_, chainId);
        emit OutboundForceResolved(operationId_, chainId, creditToSettled_);
    }

    /// @notice Body of the executor's `TRANSFER_SETTLED` branch. Applied-or-ignored, never reverts.
    /// @dev Lives here for EIP-170 headroom. Returns the `_ignore` reason (`bytes32(0)` = applied) and the two
    ///      decoded fields the executor still needs for `_acceptRemoteStateVersion`. The credit is bounded by the
    ///      recorded outbound amount on BOTH crediting paths (audit `settled_credit_not_bounded_by_outbound_amount`):
    ///      - fresh settle: moves `transfer.amount` out of `outboundInFlight_` and `min(received, amount)` into
    ///        `settled_`; the buckets reconcile exactly, and a shortfall (`received < amount`, route fee / dust) is
    ///        dropped from NAV as before and reported by `SettledCreditShortfall`;
    ///      - late credit (record already force-resolved with `creditToSettled = false`): `outboundInFlight_` was
    ///        debited by the rescue, so only the credit is applied, bounded by the same `transfer.amount` — the
    ///        value that can have reached the remote chain is still at most what was sent.
    ///      The clamp is computed only on a path that actually writes `settled_`: the `"unknown"`, `"chain"` and
    ///      `"duplicate"` returns credit nothing, so they never emit `SettledCreditClamped` — an event there would
    ///      alert on a replay rather than on a credit, and would break the invariant that the event always pairs
    ///      with a `settled_` write. A `TRANSFER_SETTLED` for a force-resolved transfer whose remote credit is
    ///      already accounted (e.g. by a crediting force-resolve, or an earlier late settle) credits nothing and is
    ///      ignored with reason `"credited"` (the state version is still consumed by the caller): it emits no
    ///      `AssetSettled` and no clamp, so `AssetSettled` is emitted only on a path that writes `settled` and an
    ///      indexer summing it cannot double count. The distinct reason lets monitoring tell a late settle after a
    ///      crediting force-resolve from a replay (`"duplicate"`). Both credit-nothing late settles (this
    ///      `"credited"` path and the IL-8619 already-attested path) still emit `SettledCreditShortfall` /
    ///      `SettledBelowMinDelivered` (IL-8581, observability only): the pool fee is otherwise invisible there, and
    ///      after a crediting force-resolve (which booked the full `amount`) NAV stays overstated by it until the
    ///      next attestation. Unlike `SettledCreditClamped` / `AssetSettled`, these events are therefore NOT paired
    ///      with a `settled_` write. A second emit on `"credited"` would need a duplicate
    ///      `TRANSFER_SETTLED`; the dispatcher sends one per receipt and CCIP executes each message once.
    ///      `remoteBalance` is returned untouched: it is peer-reported evidence for attesters, is not bounded and
    ///      is never written to NAV by this contract — it reports the dispatcher's accounted total, which includes
    ///      remote yield.
    function applyTransferSettled(
        mapping(bytes32 => Outbound) storage outbound_,
        mapping(uint256 => uint256) storage outboundInFlight_,
        mapping(uint256 => uint256) storage settled_,
        mapping(uint256 => uint64[16]) storage createdAt_,
        mapping(uint256 => uint8) storage count_,
        mapping(uint256 => uint64) storage oldest_,
        CcipAttestationState storage attestation_,
        uint256 srcChainId_,
        bytes memory data_
    ) public returns (bytes32 ignoreReason, uint256 remoteBalance, uint64 stateVersion) {
        bytes32 operationId;
        uint256 received;
        (operationId, received, remoteBalance, stateVersion) = abi.decode(data_, (bytes32, uint256, uint256, uint64));
        Outbound storage transfer = outbound_[operationId];
        if (transfer.createdAt == 0) return (bytes32("unknown"), remoteBalance, stateVersion);
        if (transfer.chainId != srcChainId_) return (bytes32("chain"), remoteBalance, stateVersion);
        if (transfer.settled) {
            // Already settled by an earlier receipt: only a force-resolved transfer still owes its
            // remote credit. Anything else is a duplicate and must be a silent no-op; a force-resolved transfer
            // whose credit is already accounted is ignored as "credited" (no second AssetSettled).
            if (!transfer.forceResolved) return (bytes32("duplicate"), remoteBalance, stateVersion);
            if (transfer.remoteCreditAccounted) {
                // Observability only (IL-8581): no accounting change. One TRANSFER_SETTLED per receipt, so no re-emit.
                _emitShortfall(transfer, srcChainId_, operationId, received);
                return (bytes32("credited"), remoteBalance, stateVersion);
            }
            _applyLateCredit(transfer, settled_, attestation_, srcChainId_, operationId, received, stateVersion);
            return (bytes32(0), remoteBalance, stateVersion);
        }
        _applyFreshSettle(
            transfer,
            outboundInFlight_,
            settled_,
            createdAt_,
            count_,
            oldest_,
            attestation_,
            srcChainId_,
            operationId,
            received
        );
        return (bytes32(0), remoteBalance, stateVersion);
    }

    /// @dev Late-credit sub-path: `transfer.settled` was already set by a force-resolve and the caller has
    ///      verified `remoteCreditAccounted` is still false, so the remote credit is applied here (unless a
    ///      repair write already priced it, IL-8619) — no `outboundInFlight_` write, that was already done by
    ///      the rescue. Split out of `applyTransferSettled` to stay under the stack-depth limit.
    function _applyLateCredit(
        Outbound storage transfer,
        mapping(uint256 => uint256) storage settled_,
        CcipAttestationState storage attestation_,
        uint256 srcChainId_,
        bytes32 operationId_,
        uint256 received_,
        uint64 stateVersion_
    ) private {
        if (
            attestation_.repairSettleSeq[srcChainId_] != transfer.resolveRepairSeq
                && stateVersion_ <= attestation_.repairSettleVersion[srcChainId_]
        ) {
            // IL-8619: the latch-clearing approval (or a force-set) after the resolve was bound to a version at or
            // above this settlement's, so it already read the delivered amount; crediting it again would count it
            // twice (NAV = S + 2A, IL-8614). A settlement with a higher version reached the dispatcher after that
            // write, which therefore cannot contain it: it is credited below (IL-8619 review).
            transfer.remoteCreditAccounted = true;
            emit LateSettlementAlreadyAttested(srcChainId_, operationId_, stateVersion_);
            // Observability only (IL-8581): the pool fee on this genuine settle must not go unreported.
            _emitShortfall(transfer, srcChainId_, operationId_, received_);
            return;
        }
        uint256 credited = received_ > transfer.amount ? transfer.amount : received_;
        if (credited != received_) {
            emit SettledCreditClamped(srcChainId_, operationId_, received_, credited);
        }
        _emitShortfall(transfer, srcChainId_, operationId_, received_);
        settled_[srcChainId_] += credited;
        // Accounting anchor credit (IL-7967): `credited` is already clamped to the recorded outbound
        // amount above, so this is value the vault verifiably sent.
        // Capped at the net principal (IL-8578 / TP-H-02) by `creditAnchor`.
        CcipExecutorAttestationLib.creditAnchor(attestation_, settled_, srcChainId_, credited);
        transfer.remoteCreditAccounted = true;
        CcipExecutorAttestationLib.bumpEpochValueMoving(attestation_, srcChainId_);
        emit AssetSettled(srcChainId_, operationId_, credited);
    }

    /// @dev Shortfall observability (IL-8581): never reverts and never blocks, so the credit of what arrived is
    ///      always booked by the caller.
    function _emitShortfall(Outbound storage transfer, uint256 chainId_, bytes32 operationId_, uint256 received_)
        private
    {
        if (received_ < transfer.amount) {
            emit SettledCreditShortfall(chainId_, operationId_, transfer.amount, received_);
        }
        if (received_ < transfer.minDeliveredSD) {
            emit SettledBelowMinDelivered(chainId_, operationId_, transfer.minDeliveredSD, received_);
        }
    }

    /// @dev Fresh-settle sub-path: first receipt for this transfer. Split out of `applyTransferSettled` to
    ///      stay under the stack-depth limit.
    function _applyFreshSettle(
        Outbound storage transfer,
        mapping(uint256 => uint256) storage outboundInFlight_,
        mapping(uint256 => uint256) storage settled_,
        mapping(uint256 => uint64[16]) storage createdAt_,
        mapping(uint256 => uint8) storage count_,
        mapping(uint256 => uint64) storage oldest_,
        CcipAttestationState storage attestation_,
        uint256 srcChainId_,
        bytes32 operationId_,
        uint256 received_
    ) private {
        uint256 credited = received_ > transfer.amount ? transfer.amount : received_;
        if (credited != received_) {
            emit SettledCreditClamped(srcChainId_, operationId_, received_, credited);
        }
        _emitShortfall(transfer, srcChainId_, operationId_, received_);
        transfer.settled = true;
        transfer.remoteCreditAccounted = true;
        outboundInFlight_[srcChainId_] -= transfer.amount;
        settled_[srcChainId_] += credited;
        // Accounting anchor credit (IL-7967): `credited` is already clamped to the recorded outbound
        // amount above, so this is value the vault verifiably sent.
        // Capped at the net principal (IL-8578 / TP-H-02) by `creditAnchor`.
        CcipExecutorAttestationLib.creditAnchor(attestation_, settled_, srcChainId_, credited);
        disarmStaleness(createdAt_, count_, oldest_, srcChainId_, transfer.stalenessSlot);
        CcipExecutorAttestationLib.bumpEpochValueMoving(attestation_, srcChainId_);
        emit AssetSettled(srcChainId_, operationId_, credited);
    }

    /// @dev `claimAsset` transfer tail (EIP-170): the ledger is already debited by the caller.
    function payOut(address asset_, address to_, uint256 amountLD_) public {
        SafeERC20.safeTransfer(IERC20(asset_), to_, amountLD_);
        emit AssetClaimed(to_, amountLD_);
    }
}

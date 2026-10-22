// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CommandStatus} from "../../lib/CrosschainConstants.sol";

/// @dev Fixed size of the per-chain unresolved-transfer staleness pool. MUST equal
///      `CrosschainConstants.MAX_PENDING_TRANSFERS_PER_CHAIN` (the concurrent-record cap). Declared as a
///      file-level literal constant because a fixed array length must be a compile-time literal/constant
///      expression; a runtime check in `StargateCrosschainExecutor`'s constructor guards against drift.
uint256 constant MAX_PENDING_TRANSFERS_PER_CHAIN_SLOTS = 16;

/// @dev `Proposal.status` values, shared by `StargateExecutorAttestationLib` and `StargateExecutorAccountingLib`.
///      SUPERSEDED: voided by an accounting-epoch bump or a newer proposal (IL-8472).
uint8 constant PROPOSAL_PENDING = 1;
uint8 constant PROPOSAL_APPROVED = 2;
uint8 constant PROPOSAL_REJECTED = 3;
uint8 constant PROPOSAL_SUPERSEDED = 4;

// =============================================================================
// Shared executor state types (spec §9).
//
// These record structs and the aggregate `StargateExecutorState` struct are extracted
// from `StargateCrosschainExecutor` verbatim so the stateful accounting/attestation/command
// logic can live in linked libraries (`StargateExecutorAccountingLib`, `StargateExecutorAttestationLib`,
// `StargateExecutorCommandLib`) that operate on `StargateExecutorState storage self` via
// delegatecall. Storage layout and semantics are IDENTICAL to the inlined
// version — only the physical location of the code changes.
// =============================================================================

/// @notice One active business command per chain.
/// @param active Whether a command occupies the slot.
/// @param isConfigUpdate Whether the command is an UPDATE_VAULTS (advances `chainConfigEpoch`).
/// @param awaitingCancel Whether a CANCEL_COMMAND was sent and an ACK is awaited as cancellation.
/// @param status PENDING or FAILED (SUCCEEDED/CANCELLED are terminal and clear the slot).
/// @param target The DEPOSIT target vault (0 for any other command).
/// @param commandId The command id bound to ACK/NACK receipts.
/// @param sequence The dispatcher sequence this command occupies.
/// @param newConfigEpoch The config epoch to commit on a successful UPDATE_VAULTS.
/// @param commitment The full command commitment `keccak256(abi.encode(uint8(msgType), innerPayload))`
///        — a permanent binding of this command id to one byte-identical operation (§9 P2 item 1/2).
struct ActiveCommand {
    bool active;
    bool isConfigUpdate;
    bool awaitingCancel;
    CommandStatus status;
    /// @dev Target vault of a DEPOSIT (0 otherwise); re-checked against the substrates on a retry (IL-8600 follow-up).
    ///      Packs into the first slot with the flags and `status` (4 + 20 bytes), so no field moves.
    address target;
    bytes32 commandId;
    uint64 sequence;
    uint64 newConfigEpoch;
    bytes32 commitment;
    /// @dev Business action of a COMMAND (0 for a config update); read by the command fuse to gate a retry (IL-8600).
    uint8 action;
    /// @dev Timestamp of the last `CANCEL_COMMAND` sent for this command (0 = none); meters repeats (IL-8579).
    ///      Appended last: packs into the slot of `action`, so no existing field moves.
    uint64 lastCancelAt;
    /// @dev IL-8625: the effective gas budget of this command (raised by a RETRY top-up) and the stored-word count of
    ///      its payload; a retry re-derives the extra `lzReceive` gas it needs from them. Appended last.
    uint64 minExecutionGas;
    uint32 payloadWords;
}

/// @notice An outbound (send) transfer awaiting a destination compose settlement.
/// @param chainId The destination chain.
/// @param guid The Stargate guid bound at send time.
/// @param amountSD The recorded expected credit (shared decimals) held in `outboundInFlight`.
/// @param createdAt Record creation timestamp.
/// @param pendingSlot The per-chain unresolved-record staleness slot this record occupies (§9 P2).
/// @param settled Whether the transfer has been settled (idempotency).
/// @param forceResolved Whether the timelocked rescue (not a receipt) set `settled` (IL-8619).
/// @param remoteCreditAccounted Whether a force-resolved record's remote credit is already in `settledRemoteBalance`
///        (a `DELIVERED_TO_SETTLED` force-resolve or a late settlement credit); an ordinary receipt does not set it,
///        only `forceResolved` records read it. False on a `DROP_FROM_NAV` record until a late `TRANSFER_SETTLED`
///        closes it with its credit.
/// @param resolveRepairSeq Unused since the IL-8619 review (the late credit is never skipped); kept for the layout.
/// @param exists Whether the record is populated.
struct OutboundRecord {
    uint256 chainId;
    bytes32 guid;
    uint256 amountSD;
    uint64 createdAt;
    uint8 pendingSlot;
    bool settled;
    bool forceResolved;
    bool remoteCreditAccounted;
    uint64 resolveRepairSeq;
    bool exists;
}

/// @notice A return (recall) awaiting metadata + delivery compose in either arrival order.
/// @param chainId The source (dispatcher) chain.
/// @param guid The bound guid (from metadata or compose, whichever arrives first).
/// @param amountSentSD Actual source-debited amount (from metadata), shared decimals.
/// @param expectedReceivedSD Expected destination credit booked into `returnInFlight` (from metadata, clamped to the
///        settled debit that metadata applied), shared decimals.
/// @param composeAmountSD Actual destination credit (from compose), shared decimals.
/// @param maxAccountedSD Upper bound on accounted return value (bound at request time).
/// @param minReturnSD Manager slippage bound (audit), shared decimals.
/// @param createdAt Record creation timestamp.
/// @param pendingSlot The per-chain unresolved-record staleness slot occupied from request creation.
/// @param pendingSlotArmed Whether `pendingSlot` currently occupies the staleness pool.
/// @param slotCounted Whether this record still holds one unit of the per-chain concurrent-record
///        capacity (`pendingTransferCount`). Tracked separately from `pendingSlotArmed` because a
///        permissionlessly cancelled recall gives its capacity back while its record lives on, and
///        late authenticated metadata may then be unable to reclaim a slot (audit M-2).
/// @param skipLateMetadataDebit Rescue tombstone flag: consume late metadata/frontier without debiting settled.
/// @param cancelled Whether the permissionless `cancelStaleReturnRequest` cancelled this request (the record stays
///        open for its late legs).
/// @param cancelClockHeld Whether this record's cancel still holds one unit of the chain's cancelled-recall clock
///        (IL-8621); cleared by the first return leg, a rejection or a force-resolve.
/// @param cancelGeneration The chain's `cancelledRecallGeneration` in force at cancel time; a record from an older
///        generation never touches a newer clock (IL-8621).
/// @param rejected Whether the dispatcher terminally rejected this request without moving value.
/// @param metadataArrived Whether RETURN_STARTED metadata has arrived.
/// @param composeArrived Whether the delivery compose has arrived.
/// @param finalized Whether the return reached a terminal normal or force-resolved state.
/// @param exists Whether the record is populated.
struct ReturnRecord {
    uint256 chainId;
    bytes32 guid;
    uint256 amountSentSD;
    uint256 expectedReceivedSD;
    uint256 composeAmountSD;
    uint256 maxAccountedSD;
    uint256 minReturnSD;
    uint64 createdAt;
    uint8 pendingSlot;
    bool pendingSlotArmed;
    bool slotCounted;
    // IL-8618 / IL-8624: this record owns booked value (`returnInFlight` or `pendingArrivalReserve`) but holds no
    // staleness slot, and is counted in `noClockReturnCount` until it is finalized.
    bool noClockCounted;
    bool skipLateMetadataDebit;
    bool cancelled;
    // IL-8621: the record's cancel armed the chain's cancelled-recall clock and no leg / resolve has cleared it yet.
    bool cancelClockHeld;
    // IL-8621: the chain's `cancelledRecallGeneration` in force when this record was cancelled.
    uint32 cancelGeneration;
    bool rejected;
    bool metadataArrived;
    bool composeArrived;
    bool finalized;
    bool exists;
}

/// @notice A pending settled-remote-balance proposal (one active per chain).
/// @param chainId The chain the proposal targets.
/// @param settledSD The proposed absolute settled balance (shared decimals).
/// @param stateVersion The remote state version bound at propose time.
/// @param remoteBlock The remote block number the observation was read at (persisted metadata, §9 P1).
/// @param remoteTimestamp The remote block timestamp the observation was read at (the freshness source
///        of truth: the chain freshness marker is set from this, not the local approval time, §9 P1).
/// @param expiry Timestamp after which the proposal cannot be approved.
/// @param trackedPositionSetHash The bound tracked-position-set hash. This is an OFF-CHAIN verification
///        commitment: the approver (a distinct role from the proposer) verifies it against the remote
///        dispatcher observation before approving. The executor does NOT hold an independent on-chain
///        expected value to compare it against (the dispatcher's set lives on the remote chain), so it
///        is persisted and emitted for the approver/monitors, never checked on-chain (§9 P1 item 6).
/// @param accountingEpochSnapshot The chain accounting epoch snapshot at propose time.
/// @param status 1 = PENDING, 2 = APPROVED, 3 = REJECTED, 4 = SUPERSEDED.
struct Proposal {
    uint256 chainId;
    uint256 settledSD;
    uint64 stateVersion;
    uint64 remoteBlock;
    uint64 remoteTimestamp;
    uint64 expiry;
    bytes32 trackedPositionSetHash;
    uint64 accountingEpochSnapshot;
    uint8 status;
}

/// @notice Aggregate mutable executor accounting/attestation state.
/// @dev Held by `StargateCrosschainExecutor` as a single storage instance and shared (by reference, via
///      delegatecall) with `StargateExecutorAccountingLib` / `StargateExecutorAttestationLib` /
///      `StargateExecutorCommandLib`. Deployment-request bookkeeping, path counters and monotonic nonces remain
///      top-level in the executor (the deployment bookkeeping is passed to `StargateExecutorDeploymentLib` as
///      separate storage references). Field order is chosen for readability; there is no proxy so the
///      exact slot layout is unobservable. Most fields are read back through an explicit executor getter
///      (`anchorPrincipal` as `attestationAnchorPrincipal`). Deliberately NOT exposed, because their getters do
///      not fit the executor's EIP-170 headroom: `outboundTransfers`, `returnRecords`, `activeReturnRequest`,
///      `netPrincipal`, `blockRaisedByNoClockReturn`, `commandLaneReceiveGas`, the unused `repairSettleSeq`, the
///      per-slot `pendingRecordCreatedAt` (only its oldest entry, as `inFlightSince`) and the `ActiveCommand`
///      fields `commitment`, `lastCancelAt`, `minExecutionGas` and `payloadWords`. Reconstruct them from events:
///      outbound records from `AssetSentToDispatcher`, `TransferSettledInbound`, `LateSettlementCredited` and
///      `TransferForceResolved`; return records and the active return request from `ReturnRequested`,
///      `ReturnMetadataApplied`, `ReturnComposeReserved`, `ReturnFinalized`, `ReturnRejectedByDispatcher`,
///      `ReturnRequestCancelled` and `TransferForceResolved` (the active request is the latest `ReturnRequested`
///      without a matching terminal or cancel event); `netPrincipal` from `AttestationNetPrincipalUpdated`; the
///      lane gas from the `registerChain` enforced options.
struct StargateExecutorState {
    // NAV buckets (SHARED decimals) — mutually exclusive (§9)
    mapping(uint256 chainId => uint256 settledSD) settledRemoteBalance;
    mapping(uint256 chainId => uint256 outboundSD) outboundInFlight;
    mapping(uint256 chainId => uint256 returnSD) returnInFlight;
    uint256 idleLedger;
    uint256 pendingArrivalReserve;
    // Per-chain unresolved-transfer staleness pool (§9 P2). Every open outbound/return record — regardless of
    // which NAV bucket currently holds its value — occupies a slot holding its creation timestamp. Exception: a
    // recall cancelled by `cancelStaleReturnRequest` releases its slot; a late leg re-arms one at its arrival
    // time, or counts the record in `noClockReturnCount` when none is free. The transfer-staleness gate is
    // measured against the OLDEST occupied slot. A slot holds 0 when free.
    // Sized to `MAX_PENDING_TRANSFERS_PER_CHAIN` (the same cap that bounds concurrent records per chain).
    mapping(uint256 chainId => uint64[MAX_PENDING_TRANSFERS_PER_CHAIN_SLOTS] createdAt) pendingRecordCreatedAt;
    mapping(uint256 chainId => uint64 version) acknowledgedRemoteStateVersion;
    mapping(uint256 chainId => uint64 epoch) accountingEpoch;
    mapping(uint256 chainId => bool blocked) chainBlocked;
    mapping(uint256 chainId => bool pending) frontierRepairPending;
    // Command slot
    mapping(uint256 chainId => ActiveCommand command) activeCommand;
    mapping(uint256 chainId => uint64 seq) nextSequenceToSend;
    mapping(uint256 chainId => uint64 epoch) chainConfigEpoch;
    // Transfer records
    mapping(bytes32 transferId => OutboundRecord record) outboundTransfers;
    mapping(bytes32 requestId => ReturnRecord record) returnRecords;
    mapping(uint256 chainId => bytes32 requestId) activeReturnRequest;
    mapping(uint256 chainId => uint256 count) pendingTransferCount;
    // Attestation
    mapping(uint256 proposalId => Proposal proposal) proposals;
    mapping(uint256 chainId => uint256 proposalId) activeProposalId;
    // Freshness marker: the REMOTE observation timestamp of the last approved proposal (NAV staleness
    // gate is measured against this, not the local approval time — §9 P1 item 4).
    mapping(uint256 chainId => uint64 at) lastApprovedObservedAt;
    // Rate-limit marker: the LOCAL timestamp of the last approval (MIN_UPDATE_INTERVAL is measured
    // against this so the observation-time freshness marker cannot double as a local cadence gate).
    mapping(uint256 chainId => uint64 at) lastApprovalAt;
    // Accounting anchor (IL-7967, audit `no_cumulative_bound_on_attested_balance_ratchet`): value the
    // vault has verifiably placed on the remote chain, net of verified returns, as far as the executor
    // can know it. Written ONLY by peer-authenticated credit/debit accounting
    // (`StargateExecutorAccountingLib._onTransferSettled` and `_applyLateCredit`, the `DELIVERED_TO_SETTLED`
    // force-resolve credit, the pro-rata reduction in `_applyReturnDebit`) and by the timelocked `forceSetSettled`
    // rebase — never raised by the attester pair. The one attester-driven write is the dust-to-zero
    // reset in `StargateExecutorAttestationLib.approve` (IL-8573): an attested zero while `settled` is
    // already within `ATTESTATION_ZERO_DUST_SD` zeroes the anchor together with that dust bucket, so it
    // can only lower the anchor to zero together with that dust bucket, never raise it.
    // `StargateExecutorAttestationLib.approve` bounds every
    // approved `settledSD` to within `ATTESTATION_ANCHOR_BAND_BPS` of this value, so the untrusted
    // proposer/approver pair can move NAV only within a band around principal the vault verifiably
    // sent, not to an arbitrary value.
    mapping(uint256 chainId => uint256 principalSD) anchorPrincipal;
    // Net principal (IL-8578 / TP-H-02): credits from peer-authenticated settles, debited by the
    // authenticated amount the dispatcher sent back on each recall (floored at zero); rebased to the new
    // settled value by `forceSetSettled`, zeroed with the anchor on the dust-to-zero approval. The
    // attesters never raise it: only authenticated returns lower it, and the dust-to-zero approval zeroes it with
    // the anchor. Caps every anchor CREDIT (`StargateExecutorAccountingLib._creditAnchor`), so a
    // recall / re-supply round trip cannot raise the anchor above the largest net principal the vault has
    // verifiably placed since the last force-set (the pro-rata recall debit shrinks the anchor by less
    // than the principal removed whenever the bucket carries unrecognised yield).
    mapping(uint256 chainId => uint256 principalSD) netPrincipal;
    // IL-8618 / IL-8624: open return records that own booked value but have no staleness slot. While non-zero the
    // chain is treated as blocked by NAV and `forceSetSettled` refuses (the record is not counted in
    // `pendingTransferCount`).
    mapping(uint256 chainId => uint32 count) noClockReturnCount;
    // IL-8624: the no-clock site raised `chainBlocked` on a chain that was not blocked before. The last record's
    // finalization lifts exactly that block; every other block-raising site resets this flag.
    mapping(uint256 chainId => bool raised) blockRaisedByNoClockReturn;
    // IL-8619: formerly the repair / force-set sequence after which a late settlement skipped its credit. Unused
    // since the IL-8619 review (on Stargate such a write never contains the late amount); kept so no later member
    // moves.
    mapping(uint256 chainId => uint64 seq) repairSettleSeq;
    // IL-8621 (parity with CCIP IL-8590): cancelled-recall clock. A permissionless cancel frees the request slot and
    // the staleness slot, but the value the recall may already have moved on the dispatcher is not yet visible here,
    // so the chain keeps ONE clock armed: the oldest cancelled request's `createdAt`. `computeNavSD` enforces the
    // transfer-staleness rule against it until every cancelled request has a return leg (metadata / compose), a
    // rejection or a force-resolve, an approval is accepted at a version past `cancelledRecallVersion`, or
    // `ADVANCE_STATE_FRONTIER` / `forceSetSettled` resets the chain (each bumps the generation so an answer to an
    // older cancel is ignored).
    mapping(uint256 chainId => uint32 count) cancelledRecallCount;
    mapping(uint256 chainId => uint64 pendingAt) cancelledRecallPendingAt;
    mapping(uint256 chainId => uint32 generation) cancelledRecallGeneration;
    // Acknowledged dispatcher state version when the most recent cancel happened.
    mapping(uint256 chainId => uint64 version) cancelledRecallVersion;
    // IL-8625: the command-lane `lzReceive` gas parsed from the enforced options at `registerChain` (paths are
    // append-only, so it never changes). Every COMMAND / UPDATE_VAULTS stamps `minExecutionGas` = this minus
    // its `/ 64` hop loss and the payload-dependent pre-call work (`COMMAND_PRE_CALL_BASE` /
    // `COMMAND_PRE_CALL_PER_WORD`, see `CrosschainMessages.commandGasBudget`), or a higher manager top-up on a
    // COMMAND. Appended last.
    mapping(uint256 chainId => uint128 gas) commandLaneReceiveGas;
}

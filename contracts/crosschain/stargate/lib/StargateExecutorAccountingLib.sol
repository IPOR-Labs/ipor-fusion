// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CrosschainErrors} from "../../lib/CrosschainErrors.sol";
import {
    CommandStatus,
    CommandResolution,
    ResolveOutcome,
    MsgType,
    CrosschainConstants
} from "../../lib/CrosschainConstants.sol";
import {
    CrosschainMessages,
    ReturnAssetsRequest,
    OutboundTransfer,
    CommandAck,
    CommandNack,
    TransferSettled,
    ReturnStarted,
    ReturnRejected
} from "../../lib/CrosschainMessages.sol";
import {
    StargateExecutorState,
    ActiveCommand,
    OutboundRecord,
    ReturnRecord,
    PROPOSAL_SUPERSEDED
} from "./StargateExecutorState.sol";

/// @title StargateExecutorAccountingLib
/// @notice The `StargateCrosschainExecutor` stateful engine (NAV accounting, command receipts / abandon / realign,
///         outbound record + recall payload construction and inbound message decode/dispatch), extracted into an
///         external linked library to keep the executor under the EIP-170 runtime limit (spec §9, §12); the
///         outbound command builders live in `StargateExecutorCommandLib`. Every function operates
///         on the executor's own storage via `StargateExecutorState storage self` (delegatecall), so behavior is
///         byte-for-byte identical to the previously-inlined implementation — only the code location
///         moves. Access control (`onlyManager`/`onlyFactory`/endpoint auth) stays on the executor;
///         these are the post-auth logic bodies. The message codec is inlined HERE (not in the executor)
///         so its encode/decode footprint leaves the executor entirely.
/// @dev Under delegatecall `address(this)` is the executor, so id derivations (`commandId`/`requestId`)
///      match the executor exactly. Amounts are in SHARED decimals; local<->shared conversion and the
///      actual LayerZero/Stargate send stay on the executor (which owns the immutables). Emitted events
///      carry identical signatures to the executor's originals, so — under delegatecall — the logs are
///      indistinguishable (same emitter address, same topics). The executor declares every library
///      event and error (directly or via `IStargateExecutorLibraryAbi`), so its ABI decodes them;
///      `CrosschainLibraryAbiCompletenessTest` enforces this.
/// @author IPOR Labs
library StargateExecutorAccountingLib {
    using SafeERC20 for IERC20;

    event AssetClaimed(address manager, uint256 amount);
    /// @notice An active balance proposal was voided without being approved or rejected, so it can no longer
    ///         be approved: either an accounting-epoch bump (a value-moving operation made the observed
    ///         snapshot stale, IL-8269) or a newer proposal for the same chain replaced it (IL-8472). The
    ///         proposal's status becomes SUPERSEDED (4) and approve / reject of it reverts `ProposalNotActive`.
    ///         `newEpoch` is the chain's accounting epoch after the void (the current epoch when a newer
    ///         proposal supersedes it).
    event ProposalInvalidated(uint256 chainId, uint256 proposalId, uint64 newEpoch);
    /// @notice An outbound transfer was settled by the peer's `TRANSFER_SETTLED` receipt.
    /// @dev Amounts are in shared decimals. `sentSD` is the recorded outbound amount. `creditedSD` is the
    ///      amount credited to `settledRemoteBalance` and the attestation anchor: the peer-reported received
    ///      amount clamped to `sentSD`. `creditedSD < sentSD` means the transfer settled below its sent amount
    ///      (route shortfall or peer under-report). An over-report is clamped to `sentSD` and additionally
    ///      raises `SettledCreditClamped`.
    event TransferSettledInbound(
        uint256 srcChainId,
        bytes32 transferId,
        bytes32 guid,
        uint256 sentSD,
        uint256 creditedSD,
        uint64 stateVersion
    );
    /// @notice Recall metadata (RETURN_STARTED) was applied to a return record.
    /// @dev `guid` is the LayerZero guid the metadata carried. `debitedSD` is the amount this step removed
    ///      from `settledRemoteBalance` (0 when the late-metadata debit is skipped). `inFlightCreditSD` is the
    ///      amount this step booked into `returnInFlight`: the clamped expected credit in order (a) (metadata
    ///      before compose); 0 in order (b) (compose first), where the actual credit goes straight to idle and
    ///      is carried by `ReturnFinalized` in the same transaction; 0 for a record already finalized (late
    ///      metadata after a no-leg DROP). Together they make the per-recall NAV bucket moves reconstructable
    ///      from logs.
    event ReturnMetadataApplied(
        uint256 srcChainId,
        bytes32 requestId,
        bytes32 guid,
        uint256 amountSentSD,
        uint256 debitedSD,
        uint256 inFlightCreditSD,
        uint64 stateVersion
    );
    event ReturnFinalized(uint256 srcChainId, bytes32 requestId, uint256 idleCreditSD);
    /// @notice An order-(b) return compose (the compose arrived BEFORE its `RETURN_STARTED` metadata) booked its
    ///         amount into `pendingArrivalReserve`. Fires for every order-(b) compose, including the late compose
    ///         after a permissionless `cancelStaleReturnRequest`, and before any
    ///         `ReturnComposeWithoutStalenessClock` raised by the same call. `amountSD` is in shared decimals.
    ///         `ReturnFinalized` closes the normal order-(b) path once the metadata arrives; a rescue closes it
    ///         with `ReturnRecordForceResolved` (plus the executor's `TransferForceResolved`).
    event ReturnComposeReserved(uint256 srcChainId, bytes32 requestId, bytes32 guid, uint256 amountSD);
    /// @notice A return record was closed by `applyForceResolve` (all amounts in shared decimals).
    ///         `inFlightRemovedSD` is the expected credit dropped from `returnInFlight` (metadata-only record,
    ///         `DROP_FROM_NAV`); `reserveToIdleSD` is the compose amount moved from `pendingArrivalReserve` to
    ///         `idleLedger` (compose-only record, `DROP_RETURN_METADATA_INCLUDED`). Both are zero when no leg had
    ///         arrived. Emitted in the same transaction as the executor's `TransferForceResolved(id, outcome)`.
    event ReturnRecordForceResolved(
        uint256 chainId,
        bytes32 requestId,
        uint8 outcome,
        uint256 inFlightRemovedSD,
        uint256 reserveToIdleSD
    );
    event ReturnRejectedByDispatcher(uint256 srcChainId, bytes32 requestId, uint8 reason);
    event ReturnDebitExceededAccountingBound(
        uint256 srcChainId,
        bytes32 requestId,
        uint256 amountSentSD,
        uint256 accountedDebitSD,
        uint256 unaccountedDebitSD
    );
    /// @notice The peer reported more than this transfer ever sent. Credited `credited` (= the recorded
    ///         outbound amount) instead of `reported`. An honest Stargate pool cannot deliver more than was
    ///         sent, so this never fires on a healthy lane: treat it as a peer-integrity incident — stop new
    ///         supply to `srcChainId`, verify the dispatcher's code and accounted balance on the remote chain,
    ///         and if the peer is not the audited dispatcher block the chain and repair through the timelocked
    ///         force-set-settled rescue. Shared decimals.
    event SettledCreditClamped(uint256 srcChainId, bytes32 transferId, uint256 reported, uint256 credited);
    /// @notice `RETURN_STARTED` reported a destination credit above the settled value this recall actually
    ///         debited. Booked `credited` (= the accounted debit) into `returnInFlight` instead of `reported`, so
    ///         recall metadata can never raise NAV; the delivery compose still credits the real delivered amount
    ///         as idle, so honest value is recognised late, never lost. Fires on a healthy lane only when the
    ///         remote idle exceeds the attested `settled` or the pool credits a reward above the sent amount.
    ///         Otherwise treat it as a peer-integrity incident, as for `SettledCreditClamped`. Shared decimals.
    event ReturnCreditClamped(uint256 srcChainId, bytes32 requestId, uint256 reported, uint256 credited);
    event LateReturnMetadataConsumedWithoutDebit(uint256 srcChainId, bytes32 requestId, uint64 stateVersion);
    /// @notice Return-in-flight value was booked without an unresolved-transfer staleness slot (the pool
    ///         was full for an abandoned recall's late metadata). The chain is blocked fail-closed and the record
    ///         is counted in `noClockReturnCount` (IL-8618) until it is finalized: by its delivery compose or the
    ///         timelocked `DROP_FROM_NAV`, either of which lifts the block when this site alone raised it
    ///         (`NoClockReturnBlockLifted`, IL-8624). Never expected in normal operation — alert.
    event ReturnInFlightWithoutStalenessClock(uint256 srcChainId, bytes32 requestId, uint256 amountReceivedSD);
    /// @notice A delivery compose landed on a recall whose staleness slot had been released by the
    ///         permissionless cancel and no slot could be reclaimed. Unlike the metadata sibling above,
    ///         the value here sits in `pendingArrivalReserve`, not `returnInFlight` — the exit differs
    ///         (`DROP_RETURN_METADATA_INCLUDED` + `forceSetSettled` vs. `DROP_FROM_NAV`), so monitoring
    ///         must be able to tell the two apart. The chain is blocked fail-closed and the record is counted
    ///         in `noClockReturnCount` (IL-8618), which blocks NAV on its own and makes `forceSetSettled` revert
    ///         `UnclockedReturnOpen` until the record is finalized. This branch also clears
    ///         `frontierRepairPending`, and a later `ADVANCE_STATE_FRONTIER` does not re-arm it over this block
    ///         (IL-8620), so an ordinary `approveBalance` cannot lift it. The late `RETURN_STARTED` finalizes
    ///         the record and lifts the block when this site alone raised it (`NoClockReturnBlockLifted`,
    ///         IL-8624); if another reason holds the block, the timelocked `forceSetSettled` lifts it. If the
    ///         metadata never lands, `applyForceResolve(DROP_RETURN_METADATA_INCLUDED)` resolves the record and the
    ///         timelocked `forceSetSettled` then lifts the block. Monitoring must not treat this block as
    ///         self-sustaining. Never expected in normal operation — alert.
    event ReturnComposeWithoutStalenessClock(uint256 srcChainId, bytes32 requestId, uint256 amountSD);
    /// @notice A `RETURN_REJECTED` arrived for a recall whose metadata or compose leg had already moved value
    ///         (IL-8447). The dispatcher sends either `RETURN_STARTED` or `RETURN_REJECTED` for a request, never
    ///         both, so this means a faulty or compromised peer. The record is left open and the chain is
    ///         blocked fail-closed; the timelocked force-resolve for the applied leg reconciles it. Never
    ///         expected in normal operation — alert.
    event ReturnRejectedAfterValueLeg(uint256 srcChainId, bytes32 requestId, bool metadataArrived, bool composeArrived);
    event CommandAcknowledged(
        uint256 srcChainId,
        bytes32 commandId,
        uint64 stateVersion,
        int256 valueDeltaSD,
        uint8 resolution
    );
    event CommandFailed(uint256 srcChainId, bytes32 commandId);
    /// @notice The dispatcher's authoritative config epoch differed from the executor's expectation and
    ///         the mirror was realigned to it. Never expected in normal operation — alert on this.
    event ConfigEpochResynced(uint256 srcChainId, uint64 expectedEpoch, uint64 dispatcherEpoch);
    /// @notice The receipt of the command a correct CONSUMED abandon freed the slot for arrived late and
    ///         refreshed the config epoch mirror (IL-8632). The sequence mirror is untouched. A command that owns
    ///         the slot at this point was built against the previous epoch (an UPDATE_VAULTS carries it + 1) and is
    ///         NACKed by the dispatcher: cancel
    ///         it and send it again. Never expected in normal operation: review the abandoned command's lane
    ///         history.
    event LateReceiptEpochAdopted(uint256 srcChainId, uint64 sequence, uint64 previousEpoch, uint64 newEpoch);
    /// @notice A command whose receipt can never arrive was terminally abandoned by the timelocked rescue,
    ///         freeing the chain's command slot. Never expected in normal operation — alert on this.
    event CommandAbandoned(uint256 chainId, bytes32 commandId, uint64 sequence, bool sequenceConsumed);
    /// @notice An authenticated receipt resolved no active command: a duplicate, a late receipt (see
    ///         `CommandReceiptAdopted` / `LateReceiptEpochAdopted`) or an `EXPIRED` receipt for a command that does
    ///         not hold the slot as FAILED. `stateVersion` is evidence only: receipts never move the version
    ///         frontier (IL-8257).
    event CommandReceiptConsumedWithoutCommand(uint256 srcChainId, bytes32 commandId, uint64 stateVersion);
    /// @notice An authenticated receipt that resolved no active command re-aligned the lane's mirrors to
    ///         the counters it carried. `supersededCommandId` is the replacement it retired, or zero when
    ///         the slot was free. Never expected in normal operation — alert on this.
    event CommandReceiptAdopted(
        uint256 srcChainId,
        bytes32 commandId,
        uint64 sequence,
        uint64 dispatcherConfigEpoch,
        bytes32 supersededCommandId
    );
    /// @notice The timelocked realign set the lane's mirrors to declared values. Never expected in normal
    ///         operation — alert on this.
    event CommandLaneRealigned(
        uint256 chainId,
        uint64 previousSequence,
        uint64 newSequence,
        uint64 previousEpoch,
        uint64 newEpoch
    );
    /// @notice An authenticated settlement arrived for an outbound record that is already resolved and owes no
    ///         credit: a duplicate, a `DELIVERED_TO_SETTLED` record (its credit was booked by the rescue) or a
    ///         record whose guid does not match. Its remote state version was consumed to keep the chain's
    ///         version frontier contiguous; no accounting was applied.
    /// @dev A genuine late settlement of a `DROP_FROM_NAV` record is NOT this event: it is credited once
    ///      (`LateSettlementCredited`), IL-8619. The return-side variant is unchanged: a `DROP_FROM_NAV`
    ///      return record whose legs arrive late lands its tokens as untracked executor surplus (outside
    ///      `idleLedger` and `pendingArrivalReserve`, see `handleReturnCompose`), recoverable only by a generic
    ///      rescue `ASSET.transfer` of the surplus (e.g. straight to the PlasmaVault, `MANAGER`). While neither
    ///      leg has arrived and they may still arrive, prefer the permissionless `cancelStaleReturnRequest`
    ///      (available once `TRANSFER_STALENESS_MAX` has elapsed), which keeps the record able to accept them,
    ///      over DROP_FROM_NAV.
    event TransferSettlementConsumedWithoutAccounting(uint256 srcChainId, bytes32 transferId, uint64 stateVersion);
    /// @notice The genuine settlement of a `DROP_FROM_NAV` outbound arrived: `credited` (= `min(received, amountSD)`)
    ///         was added to settled and the anchor, once. `amountSD` is the recorded expected credit.
    event LateSettlementCredited(
        uint256 srcChainId,
        bytes32 transferId,
        uint256 amountSD,
        uint256 credited,
        uint64 stateVersion
    );
    /// @notice Not emitted on Stargate since the IL-8619 review: the late settlement of a `DROP_FROM_NAV` outbound is
    ///         always credited (`LateSettlementCredited`, see `_applyLateCredit`). Kept so the executor ABI does not
    ///         change; CCIP still emits its twin when the write already contained the amount.
    event LateSettlementAlreadyAttested(uint256 srcChainId, bytes32 transferId, uint64 stateVersion);
    /// @notice An authenticated, version-bearing message was dropped as an "older duplicate" while the
    ///         record it names was still OPEN. A genuine LayerZero re-delivery always finds its record
    ///         already resolved (settled / metadataArrived), so this combination means
    ///         the local frontier sits ahead of the dispatcher's real counter — the signature of a frontier
    ///         repair that overshot. The bound in `applyForceResolve` makes a gross overshoot impossible;
    ///         this is the detector for a small one, which no on-chain check can catch. Never expected in
    ///         normal operation — alert on this and stop using the lane until it is reconciled.
    event AuthenticatedMessageDroppedAheadOfFrontier(
        uint256 srcChainId,
        uint8 msgType,
        bytes32 recordId,
        uint64 stateVersion,
        uint64 frontier
    );
    /// @notice The per-chain accounting anchor (`anchorPrincipal`) was rebased by the timelocked
    ///         `forceSetSettled` rescue (IL-7967, audit `no_cumulative_bound_on_attested_balance_ratchet`).
    ///         Emitted from the library (delegatecalled from the executor) so the executor spends no bytes.
    event AttestationAnchorRebased(uint256 chainId, uint256 principalSD);
    /// @notice The per-chain accounting anchor changed by a non-rebase path: a settle credit, a
    ///         DELIVERED_TO_SETTLED force-resolve credit, a pro-rata recall debit (IL-8466) or the
    ///         attester pair's dust-to-zero reset in `StargateExecutorAttestationLib.approve` (new anchor 0,
    ///         reachable only while `settled` is within `ATTESTATION_ZERO_DUST_SD`, IL-8573). The
    ///         timelocked force-set rebase emits `AttestationAnchorRebased` instead. `principalSD` is the
    ///         NEW anchor, in shared decimals.
    event AttestationAnchorUpdated(uint256 chainId, uint256 principalSD);
    /// @notice The per-chain net principal (`netPrincipal`, IL-8578 / TP-H-02) changed: a credit, a recall
    ///         debit, a force-set rebase or the dust-to-zero reset. `netPrincipalSD` is the NEW value, in
    ///         shared decimals.
    event AttestationNetPrincipalUpdated(uint256 chainId, uint256 netPrincipalSD);
    /// @notice The settled bucket was overwritten by the timelocked `forceSetSettled` rescue. Emitted from
    ///         the library (delegatecalled from the executor, which also declares it for the ABI) as the
    ///         last log of the execute call; `settledSD` is in shared decimals.
    event SettledBalanceForceSet(uint256 chainId, uint256 settledSD);
    /// @notice The last unclocked return record (IL-8618) closed through `_finalizeReturn` and the block that the
    ///         no-slot site raised was lifted again (IL-8624). Not emitted when another reason holds the block.
    event NoClockReturnBlockLifted(uint256 chainId);
    /// @notice Mirror of the executor's event: a stale recall was cancelled by `cancelStaleReturnRequest`.
    event ReturnRequestCancelled(uint256 chainId, bytes32 requestId);

    /// @dev Sends the manager `amountLD_` floored to whole shared-decimal units (`amountLD_ / conversionRate_`) and
    ///      capped at `idleLedger`, then decrements `idleLedger` by exactly the units sent. Sends nothing (and
    ///      leaves the ledger untouched) when the floored amount is zero. Emits `AssetClaimed` with the amount
    ///      actually sent in local decimals.
    function claimAsset(
        StargateExecutorState storage self,
        address asset_,
        address manager_,
        uint256 amountLD_,
        uint256 conversionRate_
    ) public {
        uint256 availableSD = self.idleLedger;
        uint256 sendSD = amountLD_ / conversionRate_;
        if (sendSD > availableSD) sendSD = availableSD;
        uint256 sendLD = sendSD * conversionRate_;
        if (sendSD != 0) {
            self.idleLedger = availableSD - sendSD;
            IERC20(asset_).safeTransfer(manager_, sendLD);
        }
        emit AssetClaimed(manager_, sendLD);
    }

    /// @dev Source-of-funds guard (invariant #4): only fresh, untracked tokens may be bridged out. Reverts
    ///      `SourceOfFundsGuard(balance, need)` unless
    ///      `balance >= (idleLedger + pendingArrivalReserve) * conversionRate_ + amountLD_`, so tokens that back
    ///      the idle ledger or a booked arrival reserve cannot be sent away.
    function validateSourceOfFunds(
        StargateExecutorState storage self,
        address asset_,
        uint256 amountLD_,
        uint256 conversionRate_
    ) public view {
        uint256 balance = IERC20(asset_).balanceOf(address(this));
        uint256 need = (self.idleLedger + self.pendingArrivalReserve) * conversionRate_ + amountLD_;
        if (balance < need) revert CrosschainErrors.SourceOfFundsGuard(balance, need);
    }

    /// @dev `_afterRescueExecuted` body (invariant #12, IL-8640; here for EIP-170): after a generic rescue the ASSET
    ///      balance must still cover `min(balanceBefore_, (idleLedger + pendingArrivalReserve) in local decimals)`.
    function checkRescueLedger(
        StargateExecutorState storage self,
        address asset_,
        uint256 balanceBefore_,
        uint256 conversionRate_
    ) public view {
        uint256 balance = IERC20(asset_).balanceOf(address(this));
        uint256 tracked = self.idleLedger * conversionRate_ + self.pendingArrivalReserve * conversionRate_;
        if (balanceBefore_ < tracked) tracked = balanceBefore_;
        if (balance < tracked) revert CrosschainErrors.RescueLedgerInvariantViolation(balance, tracked);
    }

    // ============================================================
    // Outbound: record + payload construction (post-auth bodies)
    // ============================================================

    /// @dev Record an outbound (send) transfer: recognize the expected credit as outbound-in-flight,
    ///      persist the guid-bound record and consume a pending-transfer slot. Deliberately does NOT bump the
    ///      accounting epoch (IL-8622 / TP-M-44): a send only moves value locally from idle to
    ///      `outboundInFlight`, so the dispatcher balance a pending proposal attests is unchanged; the
    ///      matching TRANSFER_SETTLED bumps the epoch and the acknowledged version when value lands. A bump
    ///      here would let a cheap one-unit send void every pending proposal (approval censorship).
    function recordOutbound(
        StargateExecutorState storage self,
        uint256 chainId_,
        bytes32 transferId_,
        bytes32 guid_,
        uint256 receivedSD_
    ) public {
        _addInFlight(self, chainId_, receivedSD_, 0);
        uint8 slot = _armPendingSlot(self, chainId_);
        self.outboundTransfers[transferId_] = OutboundRecord({
            chainId: chainId_,
            guid: guid_,
            amountSD: receivedSD_,
            createdAt: SafeCast.toUint64(block.timestamp),
            pendingSlot: slot,
            settled: false,
            forceResolved: false,
            remoteCreditAccounted: false,
            resolveRepairSeq: 0,
            exists: true
        });
    }

    /// @dev Record a return (recall) request awaiting metadata + delivery compose and return the encoded
    ///      RETURN_ASSETS_REQUEST envelope for the executor to send on the recall lane.
    function buildReturnRequest(
        StargateExecutorState storage self,
        uint256 chainId_,
        bytes32 requestId_,
        uint256 amountSD_,
        uint256 maxAccountedSD_,
        uint256 minReturnSD_
    ) public returns (bytes memory payload) {
        // A blocked chain's exit is the timelocked force-set rescue, which refuses to run while a recall is
        // active. Opening one here would let the manager hold that exit shut (IL-8292).
        if (self.chainBlocked[chainId_]) revert CrosschainErrors.ChainBlocked(chainId_);
        bytes32 activeRequestId = self.activeReturnRequest[chainId_];
        if (activeRequestId != bytes32(0)) {
            revert CrosschainErrors.ActiveReturnRequestExists(chainId_, activeRequestId);
        }
        // A floor above the accounted bound can never be satisfied regardless of remote idle: refuse the
        // request before it leaves the source chain (mirrors CcipCrosschainExecutor, IL-8119).
        if (minReturnSD_ > maxAccountedSD_) {
            revert CrosschainErrors.InvalidMinimumReturn(minReturnSD_, maxAccountedSD_);
        }
        ReturnRecord storage rec = self.returnRecords[requestId_];
        rec.chainId = chainId_;
        rec.maxAccountedSD = maxAccountedSD_;
        rec.minReturnSD = minReturnSD_;
        rec.createdAt = SafeCast.toUint64(block.timestamp);
        rec.exists = true;
        // Arm the request immediately. Besides bounding capacity this directly detects a permanently
        // lost RETURN_STARTED message, including the compose-first/lost-metadata state.
        rec.pendingSlot = _armPendingSlot(self, chainId_);
        rec.pendingSlotArmed = true;
        rec.slotCounted = true;
        self.activeReturnRequest[chainId_] = requestId_;
        payload = CrosschainMessages.encodeReturnAssetsRequest(
            ReturnAssetsRequest({
                requestId: requestId_,
                amountSD: amountSD_,
                maxAccountedSD: maxAccountedSD_,
                minReturnSD: minReturnSD_
            })
        );
    }

    // ============================================================
    // Views + pure validation (moved out of the executor)
    // ============================================================

    /// @dev Fail-closed aggregate NAV in SHARED decimals: `idleLedger + Σ(settled + outbound + return)`
    ///      over the dispatcher chains. Reverts `ChainBlocked` if any blocked chain still tracks value or any chain
    ///      has an open return record without a staleness slot (`noClockReturnCount`, IL-8618), `NavSettledStale`
    ///      if any nonzero settled bucket lacks a fresh approved observation, and `NavTransferStale` if the oldest
    ///      unresolved transfer/recall record or the cancelled-recall clock (IL-8621) is older than
    ///      `transferStalenessMax_` (§9). The executor converts the result to local decimals (`_toLD`).
    /// @dev A blocked chain whose three buckets are all zero adds nothing to the sum, so it does not gate NAV
    ///      (IL-8260). Reverting on it froze deposits and withdrawals for the whole vault until the timelocked
    ///      rescue, over a chain with no exposure. Every block-raising site that concerns value still reverts
    ///      here: the late-metadata and compose paths without a free slot count their record in
    ///      `noClockReturnCount`, which gates on its own (the compose books `pendingArrivalReserve`, outside this
    ///      sum), `DROP_RETURN_METADATA_INCLUDED` leaves the value in `settledRemoteBalance`, and a send to a
    ///      blocked chain books `outboundInFlight`. The block flag itself is untouched, so the rescue rules for
    ///      lifting it do not change.
    function computeNavSD(
        StargateExecutorState storage self,
        uint256[] storage chainIds_,
        uint256 stalenessMax_,
        uint256 transferStalenessMax_
    ) public view returns (uint256 totalSD) {
        totalSD = self.idleLedger;
        uint256 len = chainIds_.length;
        for (uint256 i; i < len; ++i) {
            uint256 chainId = chainIds_[i];
            uint256 settled = self.settledRemoteBalance[chainId];
            uint256 chainTotal = settled + self.outboundInFlight[chainId] + self.returnInFlight[chainId];
            // IL-8618: an open return record without a staleness slot blocks NAV independently of the bit.
            if ((chainTotal != 0 && self.chainBlocked[chainId]) || self.noClockReturnCount[chainId] != 0) {
                revert CrosschainErrors.ChainBlocked(chainId);
            }

            if (settled != 0) {
                uint64 last = self.lastApprovedObservedAt[chainId];
                if (last == 0 || block.timestamp - last > stalenessMax_) {
                    revert CrosschainErrors.NavSettledStale(chainId);
                }
            }
            // Transfer staleness is gated on the oldest unresolved record. A recall occupies a slot from
            // the moment it is requested (`buildReturnRequest`), so a recall whose RETURN_STARTED never
            // arrives ages this clock too.
            uint64 oldest = _oldestUnresolvedAt(self, chainId);
            if (oldest != 0 && block.timestamp - oldest > transferStalenessMax_) {
                revert CrosschainErrors.NavTransferStale(chainId);
            }
            // IL-8621: a cancelled but unresolved recall keeps its clock; its return legs may still land.
            uint64 cancelledAt = self.cancelledRecallPendingAt[chainId];
            if (cancelledAt != 0 && block.timestamp - cancelledAt > transferStalenessMax_) {
                revert CrosschainErrors.NavTransferStale(chainId);
            }
            totalSD += chainTotal;
        }
    }

    /// @dev `getBalanceUnchecked` body in SHARED decimals (IL-8611): `computeNavSD` without the staleness gates.
    ///      Still reverts `ChainBlocked` exactly where `computeNavSD` does.
    function computeBookedSD(
        StargateExecutorState storage self,
        uint256[] storage chainIds_
    ) public view returns (uint256 totalSD) {
        totalSD = self.idleLedger;
        uint256 len = chainIds_.length;
        for (uint256 i; i < len; ++i) {
            uint256 chainId = chainIds_[i];
            uint256 chainTotal = self.settledRemoteBalance[chainId] +
                self.outboundInFlight[chainId] +
                self.returnInFlight[chainId];
            if ((chainTotal != 0 && self.chainBlocked[chainId]) || self.noClockReturnCount[chainId] != 0) {
                revert CrosschainErrors.ChainBlocked(chainId);
            }
            totalSD += chainTotal;
        }
    }

    /// @dev Shape-only validation of a vault list (bounded, nonzero, deduplicated). Authoritative
    ///      code/asset/relationship checks run destination-side on the dispatcher (§9).
    function validateVaultShape(address[] calldata vaults_) public pure {
        uint256 len = vaults_.length;
        if (len > CrosschainConstants.MAX_ALLOWED_VAULTS) {
            revert CrosschainErrors.VaultsCapReached(CrosschainConstants.MAX_ALLOWED_VAULTS);
        }
        for (uint256 i; i < len; ++i) {
            address v = vaults_[i];
            if (v == address(0)) revert CrosschainErrors.InvalidVault(v);
            for (uint256 j = i + 1; j < len; ++j) {
                if (vaults_[j] == v) revert CrosschainErrors.InvalidVault(v);
            }
        }
    }

    // ============================================================
    // Inbound: decode + dispatch (single external entry per lane)
    // ============================================================

    /// @dev Decode and apply an authenticated inbound plain message (peer verified by the base). Routes
    ///      command receipts (ACK/NACK), outbound settlements, return metadata and return rejections (spec §9).
    function handleInboundMessage(
        StargateExecutorState storage self,
        MsgType msgType_,
        uint256 srcChainId_,
        bytes memory data_
    ) public {
        if (msgType_ == MsgType.ACK) {
            _onCommandAck(self, srcChainId_, CrosschainMessages.decodeCommandAck(data_));
        } else if (msgType_ == MsgType.NACK) {
            _onCommandNack(self, srcChainId_, CrosschainMessages.decodeCommandNack(data_));
        } else if (msgType_ == MsgType.TRANSFER_SETTLED) {
            _onTransferSettled(self, srcChainId_, CrosschainMessages.decodeTransferSettled(data_));
        } else if (msgType_ == MsgType.RETURN_STARTED) {
            _onReturnStarted(self, srcChainId_, CrosschainMessages.decodeReturnStarted(data_));
        } else if (msgType_ == MsgType.RETURN_REJECTED) {
            _onReturnRejected(self, srcChainId_, CrosschainMessages.decodeReturnRejected(data_));
        } else {
            revert CrosschainErrors.UnexpectedMessageType(uint8(msgType_));
        }
    }

    /// @dev Decode and apply an authenticated inbound return-asset delivery compose (spec §9). The
    ///      compose reuses the OUTBOUND_TRANSFER envelope carrying the return `requestId` in `transferId`.
    ///      `amountSD_` is the destination-credited amount already converted to shared decimals by the
    ///      executor (which owns the decimal conversion rate). Order (b): if the record's staleness slot
    ///      was released without finalizing it (today only the permissionless `cancelStaleReturn` does
    ///      that), mirror `_onReturnStarted`'s own rule — try to reclaim a slot for the newly-booked
    ///      reserve, or fail closed via `chainBlocked` if none is free. This handler must not revert on any
    ///      delivery an honest twin dispatcher can produce: it is the inbound LayerZero compose callback, and
    ///      a revert would retain the Stargate compose with the tokens already physically on the executor.
    ///      The re-arm and no-free-slot paths therefore fail closed through `chainBlocked` instead of
    ///      reverting. `ReturnNotFound`, `WrongSourceChain` and `GuidMismatch` revert on purpose: an honest
    ///      dispatcher cannot produce such a compose, so it is a peer-integrity incident. LayerZero retains the
    ///      compose, the tokens are untracked surplus (recoverable through the generic rescue), and an order-(a)
    ///      record exits through `applyForceResolve(DROP_FROM_NAV)`, after which a retry of the retained
    ///      compose is a no-op (the `finalized` early return).
    function handleReturnCompose(
        StargateExecutorState storage self,
        uint256 srcChainId_,
        bytes memory data_,
        bytes32 guid_,
        uint256 amountSD_
    ) public {
        bytes32 requestId = CrosschainMessages.decodeOutboundTransfer(data_).transferId;
        ReturnRecord storage rec = self.returnRecords[requestId];
        if (!rec.exists) revert CrosschainErrors.ReturnNotFound(requestId);
        // A force-resolved return is a terminal compose tombstone. A late Stargate delivery remains
        // physical, untracked surplus (recoverable through the delayed rescue path), but must never
        // re-enter idle/reserve accounting that the force resolution already closed. IL-8560: after a
        // DROP_FROM_NAV this is the late-leg surplus case, see `TransferSettlementConsumedWithoutAccounting`.
        if (rec.finalized) return;
        // Normal finalization implies composeArrived; this catches duplicate compose before terminal state.
        if (rec.composeArrived) return; // duplicate compose
        // Executor-side compose invariant: a valid dispatcher on chain B can never satisfy a
        // pending recall bound to chain C.
        if (rec.chainId != srcChainId_) revert CrosschainErrors.WrongSourceChain(rec.chainId, srcChainId_);

        rec.composeArrived = true;
        rec.composeAmountSD = amountSD_;
        _resolveCancelledClock(self, srcChainId_, rec);

        if (rec.metadataArrived) {
            // Order (a): finalize — replace the EXPECTED in-flight credit with the ACTUAL idle credit.
            if (rec.guid != guid_) revert CrosschainErrors.GuidMismatch(rec.guid, guid_);
            _removeInFlight(self, srcChainId_, 0, rec.expectedReceivedSD);
            self.idleLedger += amountSD_;
            _finalizeReturn(self, srcChainId_, requestId, rec);
            _bumpAccountingEpoch(self, srcChainId_);
            emit ReturnFinalized(srcChainId_, requestId, amountSD_);
        } else {
            // Order (b): tokens are physically present but not yet reconciled. Do NOT credit idle;
            // settled still counts the value. Track the reserve so the source-of-funds guard and the
            // rescue ledger invariant see these tokens (invariant #3).
            rec.guid = guid_;
            self.pendingArrivalReserve += amountSD_;
            emit ReturnComposeReserved(srcChainId_, requestId, guid_, amountSD_);

            if (!rec.pendingSlotArmed) {
                // The record's staleness slot is gone without the record being finalized (IL-7966): on
                // `HEAD` the only writer that does this is the permissionless `cancelStaleReturn`. The
                // reserve just booked above would otherwise carry no clock and no signal at all. Mirror
                // `_onReturnStarted`'s re-arm rule exactly: re-arming MUST NOT be able to revert, so simply
                // not arming the clock is the safe fallback.
                bool armed;
                if (rec.cancelled) {
                    (rec.pendingSlot, armed) = _tryArmPendingSlot(self, srcChainId_);
                    rec.slotCounted = armed;
                } else {
                    (rec.pendingSlot, armed) = _tryArmSlotForReservedReturn(self, srcChainId_);
                }
                rec.pendingSlotArmed = armed;
                if (!armed) {
                    // No slot could be reclaimed (the pool is full of newer records): the reserve has no
                    // clock. Fail closed on the chain instead of pricing unsignalled value into NAV.
                    _raiseNoClockBlock(self, srcChainId_, rec);
                    // Same rule as the four other block-raising sites that clear the latch instead of
                    // arming it (`applyForceResolve`'s DROP_RETURN_METADATA_INCLUDED branch,
                    // `_onReturnStarted`'s own no-slot branch, `_onReturnRejected`'s value-leg branch and
                    // `StargateExecutorAttestationLib.reject`):
                    // a leftover repair latch must not lift a block raised for a different reason. (The one
                    // block-raising site that arms the latch instead is `applyForceResolve`'s
                    // ADVANCE_STATE_FRONTIER branch, and only over no foreign block (IL-8620), so that block IS
                    // liftable by the next ordinary `approveBalance`.)
                    self.frontierRepairPending[srcChainId_] = false;
                    emit ReturnComposeWithoutStalenessClock(srcChainId_, requestId, amountSD_);
                }
                // An active proposal snapshot taken before this compose must not be approvable
                // afterwards, on either outcome. The plain order-(b) path for a live record (slot
                // already armed at request creation) keeps `HEAD` behaviour: no bump here.
                _bumpAccountingEpoch(self, srcChainId_);
            }
        }
    }

    // ============================================================
    // Rescue: force-set settled + force-resolve transfer (post-timelock bodies)
    // ============================================================

    /// @dev Overwrite the settled bucket (unblocking a rejected/blocked chain). `newSettledSD_` is
    ///      pre-converted to shared decimals by the executor. Emits `SettledBalanceForceSet` last.
    ///      `chainId_` must have a ready dispatcher (IL-8113): this writer pre-seeds settled, the anchor and
    ///      the freshness stamp, and registration never resets them, so a write for a chain that is not yet in
    ///      `dispatcherChainIds` would surface as phantom NAV the moment that chain went live. The executor
    ///      also checks this at schedule time; this copy is the writer's own precondition.
    /// @dev `observedStateVersion_` is the dispatcher `stateVersion` at which `newSettledSD_` was read, and it
    ///      must equal the acknowledged frontier at execute time (IL-8264) — the same binding `approve` puts on
    ///      an attestation. Without it the overwrite could already include a remote recall debit whose
    ///      `RETURN_STARTED` had not landed yet: after a `DROP_FROM_NAV` of that recall the late metadata
    ///      applies its debit on top of the overwrite, debiting `settled` and the anchor twice. With it, a
    ///      message still in flight makes the execute revert until the message lands (then reschedule), and
    ///      any debit that lands after the overwrite carries a higher version, so the observation cannot have
    ///      included it. A lost message is handled by `ADVANCE_STATE_FRONTIER` first, which turns its later
    ///      re-delivery into a duplicate.
    /// @dev Not covered: any VALUE-MOVING message (`TRANSFER_SETTLED`, `RETURN_STARTED`) that lands between
    ///      schedule and execute bumps the frontier and makes the execute revert; the manager can trigger
    ///      those (outbound transfers, recalls), so pause the vault for the rescue window (IL-8456;
    ///      `CCIP_TEST_SYSTEM_RUNBOOK.md`, "Settled force-set and frontier advance"). Command traffic —
    ///      the ACK of a REDEEM, REQUEST_SHARES, REDEEM_FROM_REQUEST, retried or cancelled command — is
    ///      value-neutral and no longer moves the frontier (IL-8257), so it cannot void a scheduled force-set.
    /// @dev This rescue is also the designed exit for a post-recall residue whose true value sits below the
    ///      attestation band because it carries an unrecognised remote loss (IL-8585).
    /// @dev IL-8646 / TP-L-18: `observedRemoteTimestamp_` is the remote (dispatcher chain) time at which
    ///      `newSettledSD_` was read. It is committed in the schedule-time hash and validated there (not in the
    ///      future, not older than `STALENESS_MAX`); it becomes `lastApprovedObservedAt`. NAV is stale right
    ///      after execute exactly when `executeTime - observedRemoteTimestamp_ > STALENESS_MAX` (`NavSettledStale`):
    ///      an observation older than `STALENESS_MAX - RESCUE_DELAY` at schedule is sufficient but not necessary,
    ///      since a late execution also ages it, and every force-set is stale when `RESCUE_DELAY >= STALENESS_MAX`.
    ///      An ordinary attestation restores freshness; the next ordinary observation must be at least this
    ///      timestamp (`ObservationOlderThanApproved`, IL-8648).
    /// @dev IL-8648 R1: the force-set must not move that clock backwards either. Unless `allowOlderThanApproved_`
    ///      (an explicit opt-out inside the schedule-time commitment, so the guardian sees it) it reverts
    ///      `ForceSetOlderThanApproved` when the committed time is older than `lastApprovedObservedAt` (equal
    ///      passes; a chain with no approval yet has 0 and passes).
    function forceSetSettled(
        StargateExecutorState storage self,
        mapping(uint256 chainId => bool ready) storage hasDispatcher_,
        uint256 chainId_,
        uint256 newSettledSD_,
        uint64 observedStateVersion_,
        uint64 observedRemoteTimestamp_,
        bool allowOlderThanApproved_
    ) public {
        if (!hasDispatcher_[chainId_]) revert CrosschainErrors.DispatcherNotReady(chainId_);
        uint64 acknowledged = self.acknowledgedRemoteStateVersion[chainId_];
        if (observedStateVersion_ != acknowledged) {
            revert CrosschainErrors.ForceSetStateVersionMismatch(chainId_, acknowledged, observedStateVersion_);
        }
        uint256 pending = self.pendingTransferCount[chainId_];
        if (pending != 0) revert CrosschainErrors.PendingTransfersExist(chainId_, pending);
        if (self.activeReturnRequest[chainId_] != bytes32(0)) {
            revert CrosschainErrors.PendingTransfersExist(chainId_, 1);
        }
        // IL-8618: a return record with booked value but no staleness slot is not in `pendingTransferCount`.
        uint32 noClock = self.noClockReturnCount[chainId_];
        if (noClock != 0) revert CrosschainErrors.UnclockedReturnOpen(chainId_, noClock);
        // IL-8648 R1: the ordinary approve never moves the NAV clock backwards; neither does a force-set,
        // unless it was scheduled as UNCHECKED (the choice is in the commitment, so the guardian saw it).
        if (!allowOlderThanApproved_ && self.lastApprovedObservedAt[chainId_] > observedRemoteTimestamp_) {
            revert CrosschainErrors.ForceSetOlderThanApproved(
                chainId_,
                observedRemoteTimestamp_,
                self.lastApprovedObservedAt[chainId_]
            );
        }
        _setSettled(self, chainId_, newSettledSD_, observedRemoteTimestamp_);
        emit SettledBalanceForceSet(chainId_, newSettledSD_);
    }

    /// @dev Schedule-time gates of `scheduleForceSetSettledBalance` (body here for EIP-170): the observed version
    ///      must not be behind the acknowledged frontier (execute requires equality) and the remote observation
    ///      time must be nonzero, not in the future and not older than `stalenessMax_` (IL-8646 / TP-L-18).
    function checkForceSetSchedule(
        StargateExecutorState storage self,
        uint256 chainId_,
        uint64 observedStateVersion_,
        uint64 observedRemoteTimestamp_,
        uint256 stalenessMax_
    ) public view {
        uint64 acknowledged = self.acknowledgedRemoteStateVersion[chainId_];
        if (observedStateVersion_ < acknowledged) {
            revert CrosschainErrors.ForceSetStateVersionMismatch(chainId_, acknowledged, observedStateVersion_);
        }
        if (
            observedRemoteTimestamp_ == 0 ||
            observedRemoteTimestamp_ > block.timestamp ||
            block.timestamp - observedRemoteTimestamp_ > stalenessMax_
        ) revert CrosschainErrors.ObservationStale(chainId_);
    }

    function _setSettled(
        StargateExecutorState storage self,
        uint256 chainId_,
        uint256 newSettledSD_,
        uint64 observedRemoteTimestamp_
    ) private {
        self.settledRemoteBalance[chainId_] = newSettledSD_;
        // Rescue overwrite is the authoritative rebase (IL-7967): the timelocked, guardian-vetoable
        // admin has confirmed the true remote value, so the accounting anchor is reset to match it —
        // this is the only place a cumulative yield/loss beyond the band is recognised.
        self.anchorPrincipal[chainId_] = newSettledSD_;
        // The net principal is rebased with the anchor (IL-8578 / TP-H-02): the rescue admin is
        // authoritative, so a force-set that recognises yield must not be capped back down by the next
        // re-supply credit.
        self.netPrincipal[chainId_] = newSettledSD_;
        emit AttestationAnchorRebased(chainId_, newSettledSD_);
        emit AttestationNetPrincipalUpdated(chainId_, newSettledSD_);
        self.chainBlocked[chainId_] = false;
        self.blockRaisedByNoClockReturn[chainId_] = false;
        // The overwrite supersedes any cancelled recall's value, so its clock goes too (IL-8621).
        _resetCancelledClock(self, chainId_);
        // The repair latch belongs to the block it armed. Resolving a frontier repair through this
        // authoritative overwrite instead of through an approved attestation used to leave the latch set
        // forever, and from then on EVERY ordinary `approve` silently lifted whatever block happened to be
        // standing — including one raised later for an unrelated reason (audit
        // `stale_frontier_repair_flag_lifts_unrelated_fail_closed_chain_block`). Consume it here.
        self.frontierRepairPending[chainId_] = false;
        // IL-8646 / TP-L-18: the NAV freshness marker is the REMOTE observation time committed in the schedule-time
        // hash, never the execute time — the figure already aged `RESCUE_DELAY` in the queue and must not get a
        // full extra `STALENESS_MAX` on top. Only the local rate-limit marker takes the local clock (§9 P1).
        self.lastApprovedObservedAt[chainId_] = observedRemoteTimestamp_;
        self.lastApprovalAt[chainId_] = SafeCast.toUint64(block.timestamp);
        _bumpAccountingEpoch(self, chainId_);
    }

    /// @dev Apply a terminal force-resolve outcome: a state-frontier repair, a command-lane realign, a
    ///      command abandon, or the resolution of an outbound transfer or a return record.
    ///      `hasDispatcher_` is read in the `ADVANCE_STATE_FRONTIER` and `REALIGN_COMMAND_LANE` branches
    ///      (IL-8113, IL-7970): those are the branches that decode a chain id from `id_` and write per-chain
    ///      state that nothing else gates. The abandon branches
    ///      also take their chain id straight from `id_`, but `_abandonCommand` requires an active command
    ///      slot, written only by `buildBusinessCommand` and `buildUpdateVaults` — reached from
    ///      `sendCommandToDispatcher` / `updatePlasmaVaults`, both `hasDispatcher`-gated, and from
    ///      `onDispatcherCreated`, which runs after `markReady` has set the flag. The outbound and return
    ///      branches take their chain from a record whose `chainId` only `recordOutbound` and
    ///      `buildReturnRequest` write, both behind `_validateTransferRequest`.
    function applyForceResolve(
        StargateExecutorState storage self,
        mapping(uint256 chainId => bool ready) storage hasDispatcher_,
        bytes32 id_,
        ResolveOutcome outcome_
    ) public {
        if (outcome_ == ResolveOutcome.ADVANCE_STATE_FRONTIER) {
            uint256 packed = uint256(id_);
            uint256 chainId = packed >> 64;
            if (!hasDispatcher_[chainId]) revert CrosschainErrors.DispatcherNotReady(chainId);
            uint64 newVersion = uint64(packed);
            uint64 current = self.acknowledgedRemoteStateVersion[chainId];
            if (newVersion <= current) {
                revert CrosschainErrors.StateVersionGap(chainId, current + 1, newVersion);
            }
            // Bound how far one repair may skip. This is the only write that moves the anti-replay frontier
            // with no authenticated message behind it, and it cannot be undone — the frontier is monotonic
            // in both writers. Overshoot the dispatcher's real counter and `_advanceVersionFrontier`
            // classifies every genuine message from then on as an "older duplicate", so its accounting is
            // dropped: settlements never leave `outboundInFlight` (eventually `NavTransferStale`), return
            // metadata never applies its remote debit. Not for the
            // skipped range only — forever, on a non-upgradeable contract (audit
            // `unbounded_irreversible_state_version_jump_silently_swallows_authenticated_messages`).
            // Sizing on Stargate: `newVersion` = (lowest version LayerZero can still deliver) - 1, taken from the
            // dispatcher's events and the packets LayerZero still retains. The dispatcher's `stateVersion()`
            // alone overshoots whenever later responses are still retained (IL-8487). See
            // `stargate/README.md`, "Frontier repair (Stargate)".
            if (uint256(newVersion) > uint256(current) + CrosschainConstants.MAX_FRONTIER_JUMP) {
                revert CrosschainErrors.FrontierAdvanceTooLarge(
                    chainId,
                    current,
                    newVersion,
                    CrosschainConstants.MAX_FRONTIER_JUMP
                );
            }
            self.acknowledgedRemoteStateVersion[chainId] = newVersion;
            _resetCancelledClock(self, chainId);
            // IL-8620: arm the latch only when this repair owns the block (no block before, or only an earlier
            // repair's). A foreign block already standing must still need the timelocked force-set.
            self.frontierRepairPending[chainId] = !self.chainBlocked[chainId] || self.frontierRepairPending[chainId];
            self.chainBlocked[chainId] = true;
            self.blockRaisedByNoClockReturn[chainId] = false;
            _bumpAccountingEpoch(self, chainId);
            return;
        }
        if (outcome_ == ResolveOutcome.REALIGN_COMMAND_LANE) {
            // The one writer that can move `nextSequenceToSend` DOWN. An executor whose mirror ran ahead —
            // a CONSUMED abandon for a command the dispatcher never resolved — stamps sequences the
            // dispatcher will never accept, and the dispatcher advances only by executing the sequence it
            // expects; every other writer of this mirror only ever raises it (`_onCommandAck` and
            // `_abandonCommand` add one, `_adoptLateReceipt` writes `sequence + 1` under a
            // `sequence >= mirror` guard), so that state is terminal without this (IL-7970).
            // It writes belief, not value: a wrong figure produces `SequenceGap` reverts or
            // `ConfigEpochMismatch` NACKs on the dispatcher and is corrected by running this again or by
            // the next adopted receipt. Both figures are read from the dispatcher's public
            // `nextCommandSequence()` / `commandConfigEpoch()` getters.
            // `id_` packs `(uint64 chainId << 192) | (uint48 expectedEpoch << 144) | (uint48 expectedSequence << 96)
            // | (uint48 newEpoch << 48) | uint48 newSequence` (IL-8652). The expected pair is the executor's own
            // `chainConfigEpoch` / `nextSequenceToSend` mirrors the rescue was armed against; execute reverts
            // `RealignStateMoved` when they changed during the delay (an authenticated ACK moved the lane), so a
            // stale rescue cannot roll the lane back over newer state. The expected pair is supplied at schedule
            // time rather than read here because the abandon and the realign are scheduled together and executed
            // back to back: the abandon moves the sequence mirror first (+1 for CONSUMED). The counters are
            // 48-bit in this id although the mirrors are uint64: a lane would need 2^48 commands to overflow the
            // field, which is unreachable; the compare widens them. A mis-packed id decodes to some other chain
            // id and is refused by the schedule-time `_requireReady` or the `hasDispatcher_` gate below
            // (IL-8113). Nothing on-chain reveals the id before execute — only its commitment hash is stored.
            // The free-slot requirement is checked here, at execute time only, so the abandon and the
            // realign can be scheduled together and executed back to back after a single delay.
            uint256 packed = uint256(id_);
            uint256 realignChainId = packed >> 192;
            if (!hasDispatcher_[realignChainId]) revert CrosschainErrors.DispatcherNotReady(realignChainId);
            if (self.activeCommand[realignChainId].active) {
                revert CrosschainErrors.ActiveCommandExists(realignChainId);
            }
            uint64 previousSequence = self.nextSequenceToSend[realignChainId];
            uint64 previousEpoch = self.chainConfigEpoch[realignChainId];
            if (uint64(uint48(packed >> 96)) != previousSequence || uint64(uint48(packed >> 144)) != previousEpoch) {
                revert CrosschainErrors.RealignStateMoved(
                    realignChainId,
                    uint64(uint48(packed >> 96)),
                    previousSequence,
                    uint64(uint48(packed >> 144)),
                    previousEpoch
                );
            }
            uint64 newSequence = uint64(uint48(packed));
            uint64 newEpoch = uint64(uint48(packed >> 48));
            self.nextSequenceToSend[realignChainId] = newSequence;
            self.chainConfigEpoch[realignChainId] = newEpoch;
            _bumpAccountingEpoch(self, realignChainId);
            emit CommandLaneRealigned(realignChainId, previousSequence, newSequence, previousEpoch, newEpoch);
            return;
        }
        if (
            outcome_ == ResolveOutcome.ABANDON_COMMAND_SEQUENCE_UNUSED ||
            outcome_ == ResolveOutcome.ABANDON_COMMAND_SEQUENCE_CONSUMED
        ) {
            _abandonCommand(self, uint256(id_), outcome_ == ResolveOutcome.ABANDON_COMMAND_SEQUENCE_CONSUMED);
            return;
        }
        OutboundRecord storage o = self.outboundTransfers[id_];
        if (o.exists && !o.settled) {
            uint256 chainId = o.chainId;
            if (outcome_ == ResolveOutcome.DELIVERED_TO_SETTLED) {
                _removeInFlight(self, chainId, o.amountSD, 0);
                self.settledRemoteBalance[chainId] += o.amountSD;
                // Accounting anchor credit (IL-7967): the rescue admin has confirmed, under timelock, that
                // this amount reached the remote chain — verifiably-sent value, so raise the anchor too.
                _creditAnchor(self, chainId, o.amountSD);
                o.remoteCreditAccounted = true;
            } else if (outcome_ == ResolveOutcome.DROP_FROM_NAV) {
                // IL-8619: a TRANSFER_SETTLED that arrives later is credited once by `_onTransferSettled`.
                _removeInFlight(self, chainId, o.amountSD, 0);
            } else {
                revert CrosschainErrors.ForceResolveWrongState(id_);
            }
            o.settled = true;
            o.forceResolved = true;
            _resolvePendingSlot(self, chainId, o.pendingSlot);
            _bumpAccountingEpoch(self, chainId);
            return;
        }

        ReturnRecord storage r = self.returnRecords[id_];
        if (r.exists && !r.finalized) {
            uint256 chainId = r.chainId;
            // Force resolution is deliberately conservative: it may discard a metadata-backed expected
            // return, but it never manufactures idle credit without an authenticated compose. When
            // compose arrived first, the authenticated remote debit is still unknown, so settled cannot
            // be reconciled safely and force resolution must wait for RETURN_STARTED metadata.
            uint256 inFlightRemovedSD;
            uint256 reserveToIdleSD;
            if (r.metadataArrived && !r.composeArrived) {
                // value sits in returnInFlight (order-(a) mid-flight)
                if (outcome_ != ResolveOutcome.DROP_FROM_NAV) {
                    revert CrosschainErrors.ForceResolveWrongState(id_);
                }
                _removeInFlight(self, chainId, 0, r.expectedReceivedSD);
                inFlightRemovedSD = r.expectedReceivedSD;
            } else if (!r.metadataArrived && r.composeArrived) {
                if (outcome_ != ResolveOutcome.DROP_RETURN_METADATA_INCLUDED) {
                    revert CrosschainErrors.ForceResolveRequiresReturnMetadata(id_);
                }
                self.pendingArrivalReserve -= r.composeAmountSD;
                self.idleLedger += r.composeAmountSD;
                reserveToIdleSD = r.composeAmountSD;
                r.skipLateMetadataDebit = true;
            } else if (!r.metadataArrived && !r.composeArrived) {
                // Nothing has moved between accounting buckets. DROP abandons the stuck request and
                // releases its staleness slot. If authenticated metadata arrives later, the terminal
                // handler below still applies its remote settled debit exactly once. IL-8560: late legs then
                // become untracked surplus; prefer `cancelStaleReturnRequest` while they may still arrive
                // (see `TransferSettlementConsumedWithoutAccounting`).
                if (
                    outcome_ != ResolveOutcome.DROP_FROM_NAV && outcome_ != ResolveOutcome.DROP_RETURN_METADATA_INCLUDED
                ) {
                    revert CrosschainErrors.ForceResolveWrongState(id_);
                }
                if (outcome_ == ResolveOutcome.DROP_RETURN_METADATA_INCLUDED) {
                    r.skipLateMetadataDebit = true;
                }
            } else {
                revert CrosschainErrors.ForceResolveWrongState(id_);
            }
            if (outcome_ == ResolveOutcome.DROP_RETURN_METADATA_INCLUDED) {
                // Fits metadata that is merely LATE. When the `RETURN_STARTED` is LOST FOR GOOD and later
                // versioned packets exist, they revert `StateVersionGap` until the frontier is advanced: run
                // `ADVANCE_STATE_FRONTIER` to just below the lost version first, let the retained packets
                // replay, then this drop + a force-set at the new frontier (the force-set clears the block
                // and the repair latch, so no fresh attestation is needed). See `stargate/README.md`,
                // "Frontier repair (Stargate)" (IL-8487).
                // The authoritative post-debit force-set is the required second half of this rescue.
                // Fail closed between the two calls if governance does not batch them atomically.
                self.chainBlocked[chainId] = true;
                self.blockRaisedByNoClockReturn[chainId] = false;
                // ...and this block in particular must not be liftable by an ordinary approval: in this
                // window the returned amount sits in BOTH `idleLedger` and `settledRemoteBalance`, and
                // BIG_CHANGE_BPS caps how far an approval could correct settled downward. See
                // `stale_frontier_repair_flag_lifts_unrelated_fail_closed_chain_block`.
                self.frontierRepairPending[chainId] = false;
            }
            emit ReturnRecordForceResolved(chainId, id_, uint8(outcome_), inFlightRemovedSD, reserveToIdleSD);
            _finalizeReturn(self, chainId, id_, r);
            _bumpAccountingEpoch(self, chainId);
            return;
        }

        revert CrosschainErrors.TransferNotFound(id_);
    }

    /// @dev Terminal exit for a command whose receipt can never arrive (audit
    ///      `no_recovery_path_for_stuck_pending_command_bricks_command_lane`). The slot holds exactly one
    ///      command per chain and every ordinary way out needs that receipt: `buildBusinessCommand` and
    ///      `updatePlasmaVaults` refuse while the slot is occupied, `buildRetry`/`buildCancel` require the
    ///      NACK-driven FAILED state, and the only `delete` lives in the ACK handler. A dropped or
    ///      permanently unexecutable receipt therefore froze the whole business-command lane for that
    ///      chain — including the REDEEM path out of the remote ERC-4626 vaults — on non-upgradeable
    ///      contracts. (Before IL-8257 the documented repair for a lost message, `ADVANCE_STATE_FRONTIER`,
    ///      made this state certain: it pushed the frontier past the receipt's version, so a later redelivery
    ///      was classified as a duplicate. A receipt no longer carries a frontier version, so that repair
    ///      cannot swallow one.)
    ///
    ///      The value accounting is untouched on purpose. Business commands move value only on the remote
    ///      side (`valueDeltaSD` is always zero on this codec) and the recalled value is still counted in
    ///      `settledRemoteBalance`, which carries its own freshness gate — so freeing the slot is
    ///      accounting-neutral. What it is NOT is trust-free: `sequenceConsumed_` is an operator
    ///      declaration about remote state the executor cannot observe, and getting it wrong desyncs the
    ///      command sequence. That is why this sits behind the timelocked, guardian-vetoable rescue rather
    ///      than on the manager path. The desync is no longer terminal, though: a receipt that arrives
    ///      after all overrides the declaration (`_adoptLateReceipt`), and otherwise
    ///      `REALIGN_COMMAND_LANE` sets both mirrors to the dispatcher's observed counters in either
    ///      direction (IL-7970). The abandon does not touch the config epoch mirror (it has no observation of
    ///      it): an epoch advanced by the abandoned command (an UPDATE_VAULTS) reaches this side only through
    ///      its late receipt, which `_adoptLateReceipt` applies to the epoch mirror alone (IL-8632).
    function _abandonCommand(StargateExecutorState storage self, uint256 chainId_, bool sequenceConsumed_) private {
        ActiveCommand storage ac = self.activeCommand[chainId_];
        if (!ac.active) revert CrosschainErrors.NoStuckCommand(chainId_);
        bytes32 commandId = ac.commandId;
        uint64 sequence = ac.sequence;
        // Only a command that can no longer execute may be abandoned. Until its deadline has passed on the
        // dispatcher's clock too, a packet the transport retained — the COMMAND itself, or a RETRY_COMMAND —
        // could still run it after the slot is reused, and the replacement would then be superseded by its
        // receipt (IL-8255). Applies to both declarations: a CONSUMED one may be wrong.
        uint256 abandonableAt = CrosschainMessages.commandDeadline(commandId) +
            CrosschainConstants.COMMAND_EXPIRY_MARGIN;
        if (block.timestamp <= abandonableAt) revert CrosschainErrors.CommandNotExpired(commandId, abandonableAt);
        // Both a success and a cancel advance the dispatcher's sequence by one, so the mirror must follow
        // whenever the dispatcher actually resolved the command. A command it never received leaves its
        // sequence untouched, and that sequence is simply reused by the next send under a new command id.
        if (sequenceConsumed_) {
            unchecked {
                ++self.nextSequenceToSend[chainId_];
            }
        }
        delete self.activeCommand[chainId_];
        _bumpAccountingEpoch(self, chainId_);
        emit CommandAbandoned(chainId_, commandId, sequence, sequenceConsumed_);
    }

    // ============================================================
    // Inbound handler bodies (internal — inlined within the library)
    // ============================================================

    /// @notice An authenticated `EXPIRED` receipt freed the lane's slot held by a FAILED command the dispatcher
    ///         closed past its deadline without consuming its sequence (IL-8594). The sequence mirror is
    ///         unchanged, so the next command reuses `sequence`.
    event CommandExpiryReleased(uint256 chainId, bytes32 commandId, uint64 sequence);

    /// @dev Applies an authenticated command receipt. `SUCCEEDED` / `CANCELLED` resolve the active command and
    ///      advance the sequence mirror; `EXPIRED` (IL-8594) only releases a FAILED active command, leaving the
    ///      mirror alone. Receipts naming no active command go to `_adoptLateReceipt`.
    function _onCommandAck(StargateExecutorState storage self, uint256 srcChainId_, CommandAck memory ack_) internal {
        ActiveCommand storage ac = self.activeCommand[srcChainId_];
        if (ack_.resolution == CommandResolution.EXPIRED) {
            // `EXPIRED` means the dispatcher closed the command WITHOUT consuming its sequence. It frees the slot
            // only for the exact command that holds it as FAILED (same id, same sequence); any other state (free
            // slot, a replacement, a PENDING command) ignores it. It never reaches `_adoptLateReceipt` and never
            // touches `nextSequenceToSend` or the config epoch mirror. The accounting epoch is bumped like every
            // other release of this slot (CANCELLED/SUCCEEDED receipt, abandon), so a proposal armed over the
            // blocked lane is invalidated.
            if (
                ac.active &&
                ac.commandId == ack_.commandId &&
                ac.sequence == ack_.sequence &&
                ac.status == CommandStatus.FAILED
            ) {
                delete self.activeCommand[srcChainId_];
                _bumpAccountingEpoch(self, srcChainId_);
                emit CommandExpiryReleased(srcChainId_, ack_.commandId, ack_.sequence);
            } else {
                // Ignored: surfaced like every other receipt that resolves no active command.
                emit CommandReceiptConsumedWithoutCommand(srcChainId_, ack_.commandId, ack_.stateVersion);
            }
            return;
        }
        // A command receipt is value-neutral (IL-8257): it carries the dispatcher's CURRENT state version as
        // evidence and never moves `acknowledgedRemoteStateVersion` — only `TRANSFER_SETTLED` and
        // `RETURN_STARTED` do. Duplicate and late-receipt safety therefore comes from command identity and
        // sequence alone: a receipt that resolves the active command is applied once (applying deletes the
        // active command, so a redelivery no longer matches), and one that resolves no active command goes to
        // `_adoptLateReceipt`, which adopts it only at or above the sequence mirror (below it, only the receipt for
        // exactly `nextSequenceToSend - 1` may refresh the config epoch mirror, IL-8632). The pre-fix shape
        // consumed the ACK's version on the frontier, so a receipt landing ahead of a still in-transit value
        // response either gapped or, worse, made the value response look like an "older duplicate".
        // The `ABANDON_COMMAND_*` rescue frees the slot precisely while a receipt may still be in flight;
        // `_adoptLateReceipt` below takes the dispatcher's counters when they are news to this side (IL-7970).
        bool resolvesActive = ac.active && ac.commandId == ack_.commandId;
        if (resolvesActive) {
            // The receipt must resolve the EXACT active command: its sequence must match the one bound to
            // this command id. A matching id with a different sequence is an impossible/forged receipt
            // (§9 P2). These two stay fail-closed — they indicate a compromised or buggy dispatcher, not
            // a transport fault — and the `ABANDON_COMMAND_*` rescue is the exit if one ever fires.
            if (ac.sequence != ack_.sequence) {
                revert CrosschainErrors.ReceiptSequenceMismatch(ac.sequence, ack_.sequence);
            }
            // For the POC every business/config command reports a zero settled delta (value stays remote).
            // A nonzero delta is never trusted from an arbitrary receipt field (§9 P2 item 7); adding
            // signed deltas later requires an explicit per-action policy, not this field.
            if (ack_.valueDeltaSD != 0) revert CrosschainErrors.UnexpectedValueDelta(ack_.valueDeltaSD);
        }
        if (!resolvesActive) {
            // The receipt resolves no active command here. `_adoptLateReceipt` either takes its counters
            // (sequence at or above the mirror) or, for a receipt below the mirror, deliberately leaves them
            // alone — a duplicate, or one a correct CONSUMED abandon already accounted for — except that the
            // receipt for exactly `nextSequenceToSend - 1` may refresh the epoch mirror (IL-8632). Surface it
            // either way: in normal operation every ACK resolves the command it names.
            _adoptLateReceipt(self, srcChainId_, ack_);
            emit CommandReceiptConsumedWithoutCommand(srcChainId_, ack_.commandId, ack_.stateVersion);
            return;
        }

        // The dispatcher OWNS `commandConfigEpoch`; the executor only mirrors it. The mirror is therefore taken
        // from the authenticated receipt, never derived from a local flag: a CANCEL and a RETRY can both
        // be in flight for the same command, so `awaitingCancel` is ambiguous by the time the resolution
        // lands and reading it here desynced the two sides permanently (audit
        // `config_epoch_desync_via_retry_clearing_in_flight_cancel`). Adopting the authoritative value
        // instead of failing closed keeps the command lane recoverable: a divergence self-heals on the
        // next receipt and is surfaced for monitoring rather than bricking the slot.
        uint64 expectedEpoch = (ack_.resolution == CommandResolution.SUCCEEDED && ac.isConfigUpdate)
            ? ac.newConfigEpoch
            : self.chainConfigEpoch[srcChainId_];
        if (ack_.dispatcherConfigEpoch != expectedEpoch) {
            emit ConfigEpochResynced(srcChainId_, expectedEpoch, ack_.dispatcherConfigEpoch);
        }
        self.chainConfigEpoch[srcChainId_] = ack_.dispatcherConfigEpoch;
        // Both a success and a cancel advance the dispatcher's sequence by one (lockstep).
        unchecked {
            ++self.nextSequenceToSend[srcChainId_];
        }
        delete self.activeCommand[srcChainId_];
        _bumpAccountingEpoch(self, srcChainId_);
        emit CommandAcknowledged(
            srcChainId_,
            ack_.commandId,
            ack_.stateVersion,
            ack_.valueDeltaSD,
            uint8(ack_.resolution)
        );
    }

    /// @dev Mirror of `CcipExecutorCommandLib._adoptLateReceipt` (IL-7970). A receipt that resolves no
    ///      active command still carries the dispatcher's counters as of after it resolved `ack_.sequence`
    ///      — `_executeStoredCommand` and `_onCancelCommand` are the dispatcher's only two writers of
    ///      `nextCommandSequence` and both `++` it, so the receipt proves that counter is at least
    ///      `ack_.sequence + 1`. At or above the mirror those are facts this side has not accounted for
    ///      (the abandon that freed the slot declared them from no observation) and they are adopted;
    ///      below the mirror the receipt is a transport duplicate or one the abandon already accounted
    ///      for, and nothing is written, except that the receipt for exactly `nextSequenceToSend - 1` refreshes
    ///      `chainConfigEpoch` when its epoch is newer, whether or not a later command owns the slot (IL-8632).
    ///      This path only ever raises `nextSequenceToSend`; `REALIGN_COMMAND_LANE` is the one writer that can
    ///      lower it.
    ///
    ///      A replacement in the slot whose `sequence <= ack_.sequence` can never execute — the
    ///      dispatcher's counter is strictly monotonic and already past it, so its packet reverts
    ///      `SequenceGap` on every delivery attempt — and is superseded here rather than left for a second
    ///      timelocked abandon.
    ///
    ///      NEVER reverts: every branch returns and `ack_.sequence + 1` cannot wrap. The dispatcher's
    ///      `++nextCommandSequence` is `unchecked` on this transport, so the bound is not a checked revert but
    ///      the counter's own reachability: it advances by one per resolved command, so a receipt at
    ///      `type(uint64).max` is unreachable within any deployment's lifetime.
    function _adoptLateReceipt(
        StargateExecutorState storage self,
        uint256 srcChainId_,
        CommandAck memory ack_
    ) private {
        uint64 nextSequence = self.nextSequenceToSend[srcChainId_];
        ActiveCommand storage ac = self.activeCommand[srcChainId_];
        if (ack_.sequence < nextSequence) {
            // The receipt of the command a correct CONSUMED abandon just accounted for
            // (`sequence == nextSequence - 1`) is the only authenticated source of the dispatcher's config
            // epoch after that command (an UPDATE_VAULTS advances it), and the abandon cannot carry it. It
            // refreshes the epoch mirror only; the sequence was already advanced (IL-8632). It does so even when
            // a command built after the abandon owns the slot: that command carries the older mirror (an
            // UPDATE_VAULTS carries mirror + 1), which the dispatcher (whose epoch only grows) has already
            // passed, so it is NACKed whatever happens here, and a receipt ignored now is never delivered again.
            // The slot is left alone: that command still needs its own NACK and CANCEL (or EXPIRED) receipt. An
            // older receipt or an epoch that is not newer stays ignored, so a transport duplicate of an applied
            // receipt is a no-op.
            uint64 currentEpoch = self.chainConfigEpoch[srcChainId_];
            if (ack_.sequence + 1 == nextSequence && ack_.dispatcherConfigEpoch > currentEpoch) {
                self.chainConfigEpoch[srcChainId_] = ack_.dispatcherConfigEpoch;
                emit LateReceiptEpochAdopted(srcChainId_, ack_.sequence, currentEpoch, ack_.dispatcherConfigEpoch);
            }
            return;
        }
        bytes32 superseded;
        if (ac.active && ac.sequence <= ack_.sequence) {
            superseded = ac.commandId;
            delete self.activeCommand[srcChainId_];
        }
        uint64 previousEpoch = self.chainConfigEpoch[srcChainId_];
        unchecked {
            self.nextSequenceToSend[srcChainId_] = ack_.sequence + 1;
        }
        self.chainConfigEpoch[srcChainId_] = ack_.dispatcherConfigEpoch;
        if (ack_.dispatcherConfigEpoch != previousEpoch) {
            emit ConfigEpochResynced(srcChainId_, previousEpoch, ack_.dispatcherConfigEpoch);
        }
        _bumpAccountingEpoch(self, srcChainId_);
        emit CommandReceiptAdopted(srcChainId_, ack_.commandId, ack_.sequence, ack_.dispatcherConfigEpoch, superseded);
    }

    function _onCommandNack(
        StargateExecutorState storage self,
        uint256 srcChainId_,
        CommandNack memory nack_
    ) internal {
        ActiveCommand storage ac = self.activeCommand[srcChainId_];
        if (!ac.active || ac.commandId != nack_.commandId) return;
        // Bind the receipt to the exact active command's sequence (§9 P2 item 6).
        if (ac.sequence != nack_.sequence) {
            revert CrosschainErrors.ReceiptSequenceMismatch(ac.sequence, nack_.sequence);
        }
        if (ac.status == CommandStatus.FAILED) return; // duplicate NACK
        // A NACK carries no state version and does not advance the frontier or the sequence; the slot
        // stays occupied (FAILED) until an authenticated retry or cancel resolves it (§9).
        ac.status = CommandStatus.FAILED;
        emit CommandFailed(srcChainId_, nack_.commandId);
    }

    function _onTransferSettled(
        StargateExecutorState storage self,
        uint256 srcChainId_,
        TransferSettled memory ts_
    ) internal {
        OutboundRecord storage rec = self.outboundTransfers[ts_.transferId];
        if (!rec.exists) revert CrosschainErrors.TransferNotFound(ts_.transferId);
        // Bind the message to the record's chain BEFORE it is allowed to move that chain's frontier.
        if (rec.chainId != srcChainId_) revert CrosschainErrors.WrongSourceChain(rec.chainId, srcChainId_);
        // A settlement whose record is already resolved applies nothing — but it still carries a remote
        // state version that only this message will ever deliver, so the frontier must consume it below
        // before the handler returns. Returning here instead (the pre-fix shape) left a permanent gap that
        // reverted every later message on the lane, and it is reachable for real: `applyForceResolve`
        // (DELIVERED_TO_SETTLED / DROP_FROM_NAV) sets `settled` precisely while a genuine settlement may
        // still be in flight (audit `version_frontier_stall_bricks_inbound_message_lane`). Same shape as
        // the `rec.finalized` branch of `_onReturnStarted` (receipts no longer carry a frontier version, IL-8257).
        bool alreadyResolved = rec.settled;
        if (_advanceVersionFrontier(self, srcChainId_, ts_.stateVersion)) {
            // A real LayerZero re-delivery always finds its record already settled. Still open means this
            // was NOT a re-delivery: an authenticated settlement for an open record was just dropped,
            // stranding its value in `outboundInFlight` with its staleness clock running.
            if (!alreadyResolved) {
                _alertDroppedAheadOfFrontier(
                    self,
                    srcChainId_,
                    MsgType.TRANSFER_SETTLED,
                    ts_.transferId,
                    ts_.stateVersion
                );
            }
            return;
        }
        if (alreadyResolved) {
            // Never revert past this point for a resolved record — the lane must stay unbricked. Only a
            // DROP_FROM_NAV record whose guid matches still owes its remote credit (IL-8619).
            if (rec.forceResolved && !rec.remoteCreditAccounted && rec.guid == ts_.guid) {
                _applyLateCredit(self, srcChainId_, rec, ts_);
            } else {
                emit TransferSettlementConsumedWithoutAccounting(srcChainId_, ts_.transferId, ts_.stateVersion);
            }
            return;
        }
        if (rec.guid != ts_.guid) revert CrosschainErrors.GuidMismatch(rec.guid, ts_.guid);

        // Move the recorded expected credit out of outbound and the actual credited amount into settled;
        // a route shortfall is recognized here. The credit is bounded by the recorded outbound
        // amount: an honest pool cannot deliver more than was sent, and the peer's word must not become NAV
        // beyond it (audit `settled_credit_not_bounded_by_outbound_amount`, filed against CCIP — same hole here).
        uint256 credited = ts_.amountReceivedSD > rec.amountSD ? rec.amountSD : ts_.amountReceivedSD;
        if (credited != ts_.amountReceivedSD) {
            emit SettledCreditClamped(srcChainId_, ts_.transferId, ts_.amountReceivedSD, credited);
        }
        _removeInFlight(self, srcChainId_, rec.amountSD, 0);
        self.settledRemoteBalance[srcChainId_] += credited;
        // Accounting anchor credit (IL-7967): `credited` is already clamped to the recorded outbound
        // amount above, so this is value the vault verifiably sent — raise the anchor by the same amount
        // settled just moved by. Inbound handler: `+=` only, no revert.
        _creditAnchor(self, srcChainId_, credited);
        rec.settled = true;
        _resolvePendingSlot(self, srcChainId_, rec.pendingSlot);
        _bumpAccountingEpoch(self, srcChainId_);
        emit TransferSettledInbound(srcChainId_, ts_.transferId, ts_.guid, rec.amountSD, credited, ts_.stateVersion);
    }

    /// @dev IL-8619: the genuine settlement of a `DROP_FROM_NAV` outbound. Credits `min(received, amount)` to
    ///      settled and the anchor once and closes the record. Never skipped (IL-8619 review): a settlement reaches
    ///      this path only at frontier + 1 (a lower version is dropped earlier as a duplicate), while the writes that
    ///      can price the chain after the resolve (the latch-clearing approval, `forceSetSettled`) are bound to the
    ///      frontier at their time. Their balance was read at a lower version, so it cannot contain this amount.
    function _applyLateCredit(
        StargateExecutorState storage self,
        uint256 srcChainId_,
        OutboundRecord storage rec,
        TransferSettled memory ts_
    ) private {
        rec.remoteCreditAccounted = true;
        uint256 credited = ts_.amountReceivedSD > rec.amountSD ? rec.amountSD : ts_.amountReceivedSD;
        if (credited != ts_.amountReceivedSD) {
            emit SettledCreditClamped(srcChainId_, ts_.transferId, ts_.amountReceivedSD, credited);
        }
        self.settledRemoteBalance[srcChainId_] += credited;
        _creditAnchor(self, srcChainId_, credited);
        _bumpAccountingEpoch(self, srcChainId_);
        emit LateSettlementCredited(srcChainId_, ts_.transferId, rec.amountSD, credited, ts_.stateVersion);
    }

    function _onReturnStarted(
        StargateExecutorState storage self,
        uint256 srcChainId_,
        ReturnStarted memory rs_
    ) internal {
        ReturnRecord storage rec = self.returnRecords[rs_.requestId];
        if (!rec.exists) revert CrosschainErrors.ReturnNotFound(rs_.requestId);
        if (rec.finalized) {
            // A no-leg DROP may be followed by late authenticated metadata. Preserve the contiguous
            // version frontier and apply only the remote debit that was unknowable at force-resolve
            // time. The terminal tombstone intentionally does not recreate returnInFlight or credit
            // idle; any later compose is ignored by handleReturnCompose and remains untracked surplus.
            if (rec.metadataArrived) return;
            if (rec.chainId != srcChainId_) revert CrosschainErrors.WrongSourceChain(rec.chainId, srcChainId_);
            if (_advanceVersionFrontier(self, srcChainId_, rs_.stateVersion)) {
                _alertDroppedAheadOfFrontier(
                    self,
                    srcChainId_,
                    MsgType.RETURN_STARTED,
                    rs_.requestId,
                    rs_.stateVersion
                );
                return;
            }
            rec.metadataArrived = true;
            rec.amountSentSD = rs_.amountSentSD;
            rec.guid = rs_.guid;
            uint256 lateDebitedSD;
            if (rec.skipLateMetadataDebit) {
                emit LateReturnMetadataConsumedWithoutDebit(srcChainId_, rs_.requestId, rs_.stateVersion);
            } else {
                lateDebitedSD = _applyReturnDebit(
                    self,
                    srcChainId_,
                    rs_.requestId,
                    rec,
                    rs_.amountSentSD,
                    rs_.remoteBalanceSD
                );
            }
            _bumpAccountingEpoch(self, srcChainId_);
            emit ReturnMetadataApplied(
                srcChainId_,
                rs_.requestId,
                rs_.guid,
                rs_.amountSentSD,
                lateDebitedSD,
                0,
                rs_.stateVersion
            );
            return;
        }
        // Normal finalization implies metadataArrived; this catches duplicate metadata before terminal state.
        if (rec.metadataArrived) return; // duplicate metadata
        if (rec.chainId != srcChainId_) revert CrosschainErrors.WrongSourceChain(rec.chainId, srcChainId_);
        if (_advanceVersionFrontier(self, srcChainId_, rs_.stateVersion)) {
            // Past the `rec.metadataArrived` short-circuit: the recall's only authenticated remote debit
            // was just dropped, so `settledRemoteBalance` keeps counting value the remote side has sent.
            _alertDroppedAheadOfFrontier(self, srcChainId_, MsgType.RETURN_STARTED, rs_.requestId, rs_.stateVersion);
            return;
        }

        rec.metadataArrived = true;
        rec.amountSentSD = rs_.amountSentSD;
        _resolveCancelledClock(self, srcChainId_, rec);
        if (!rec.pendingSlotArmed) {
            // Re-arming MUST NOT be able to revert. A permissionless `cancelStaleReturn` hands the
            // record's capacity back, so by the time late authenticated metadata lands the pool can be
            // full of newer transfers. Reverting here would leave the inbound message permanently
            // unexecutable, freezing the chain's version frontier and blocking NAV for good (audit M-2).
            // The record is already abandoned, so simply not arming its staleness clock is safe — the
            // remote debit below still applies exactly once.
            bool armed;
            if (rec.cancelled) {
                (rec.pendingSlot, armed) = _tryArmPendingSlot(self, srcChainId_);
                rec.slotCounted = armed;
            } else {
                (rec.pendingSlot, armed) = _tryArmSlotForReservedReturn(self, srcChainId_);
            }
            rec.pendingSlotArmed = armed;
        }

        // Never let authenticated metadata brick the contiguous lane. The request-bound/accounted
        // portion is debited; any excess is surfaced for attestation/reconciliation.
        uint256 accountedDebitSD = _applyReturnDebit(
            self,
            srcChainId_,
            rs_.requestId,
            rec,
            rs_.amountSentSD,
            rs_.remoteBalanceSD
        );

        // The expected credit is bounded by what this recall just debited from settled: metadata only moves
        // value between buckets, and the peer's figure must not become NAV beyond it (IL-8293 / IL-8264 M-09,
        // the return-leg sibling of `settled_credit_not_bounded_by_outbound_amount`). Stored clamped because the
        // compose and `DROP_FROM_NAV` remove exactly `expectedReceivedSD` from `returnInFlight`.
        uint256 credited = rs_.amountReceivedSD > accountedDebitSD ? accountedDebitSD : rs_.amountReceivedSD;
        if (credited != rs_.amountReceivedSD) {
            emit ReturnCreditClamped(srcChainId_, rs_.requestId, rs_.amountReceivedSD, credited);
        }
        rec.expectedReceivedSD = credited;

        if (rec.composeArrived) {
            // Order (b): the compose already credited tokens into `pendingArrivalReserve`. Finalize now:
            // recognize the ACTUAL received amount as idle and release the reserve. Never touch
            // `returnInFlight` in this order (invariant #3).
            if (rec.guid != rs_.guid) revert CrosschainErrors.GuidMismatch(rec.guid, rs_.guid);
            self.idleLedger += rec.composeAmountSD;
            self.pendingArrivalReserve -= rec.composeAmountSD;
            _finalizeReturn(self, srcChainId_, rs_.requestId, rec);
            emit ReturnFinalized(srcChainId_, rs_.requestId, rec.composeAmountSD);
        } else {
            // Order (a): recognize the (clamped) EXPECTED received amount as return-in-flight; the later
            // compose replaces expected-with-actual.
            rec.guid = rs_.guid;
            _addInFlight(self, srcChainId_, 0, credited);
            if (!rec.pendingSlotArmed) {
                // Late metadata for an abandoned recall could not reclaim a staleness slot (the pool is
                // full of newer records), yet it just booked value into `returnInFlight`. That value would
                // be priced into NAV with NO staleness clock, so fail closed on the chain instead: the
                // handler still completes (never revert here — the version frontier must stay contiguous),
                // but NAV is gated until the record is finalized (its delivery compose or the timelocked rescue).
                // Alert on this event.
                _raiseNoClockBlock(self, srcChainId_, rec);
                // Same rule as the other four block-raising paths that clear the latch: a leftover repair
                // latch must not lift a block raised for a different reason.
                self.frontierRepairPending[srcChainId_] = false;
                emit ReturnInFlightWithoutStalenessClock(srcChainId_, rs_.requestId, credited);
            }
        }
        _bumpAccountingEpoch(self, srcChainId_);
        emit ReturnMetadataApplied(
            srcChainId_,
            rs_.requestId,
            rs_.guid,
            rs_.amountSentSD,
            accountedDebitSD,
            rec.composeArrived ? 0 : credited,
            rs_.stateVersion
        );
    }

    function _onReturnRejected(
        StargateExecutorState storage self,
        uint256 srcChainId_,
        ReturnRejected memory rejected_
    ) internal {
        ReturnRecord storage rec = self.returnRecords[rejected_.requestId];
        if (!rec.exists) revert CrosschainErrors.ReturnNotFound(rejected_.requestId);
        if (rec.chainId != srcChainId_) revert CrosschainErrors.WrongSourceChain(rec.chainId, srcChainId_);
        if (rec.finalized) return;
        if (rec.metadataArrived || rec.composeArrived) {
            // A value leg is already booked (`returnInFlight` or `pendingArrivalReserve`): finalizing here would
            // strand it. Never revert an inbound handler; leave the record open for the leg-specific
            // force-resolve and fail closed on the chain. Same latch rule as the other block-raising sites that
            // clear it: a leftover repair latch must not lift a block raised for a different reason.
            self.chainBlocked[srcChainId_] = true;
            self.blockRaisedByNoClockReturn[srcChainId_] = false;
            self.frontierRepairPending[srcChainId_] = false;
            emit ReturnRejectedAfterValueLeg(srcChainId_, rejected_.requestId, rec.metadataArrived, rec.composeArrived);
            return;
        }
        rec.rejected = true;
        _finalizeReturn(self, srcChainId_, rejected_.requestId, rec);
        // No epoch bump (IL-8622 / TP-M-44): a rejected return moved no value on either side (IL-8257), so a
        // pending proposal stays true.
        emit ReturnRejectedByDispatcher(srcChainId_, rejected_.requestId, uint8(rejected_.reason));
    }

    // ============================================================
    // Internal helpers (inlined within the library)
    // ============================================================

    /// @dev Advance the per-chain contiguous version frontier by exactly one. Returns true when the
    ///      version is an older duplicate (caller no-ops); reverts on a gap (LZ retains for retry).
    function _advanceVersionFrontier(
        StargateExecutorState storage self,
        uint256 chainId_,
        uint64 msgStateVersion_
    ) internal returns (bool isDuplicate) {
        uint64 ack = self.acknowledgedRemoteStateVersion[chainId_];
        if (msgStateVersion_ <= ack) return true;
        if (msgStateVersion_ != ack + 1) {
            revert CrosschainErrors.StateVersionGap(chainId_, ack + 1, msgStateVersion_);
        }
        self.acknowledgedRemoteStateVersion[chainId_] = msgStateVersion_;
        return false;
    }

    /// @dev Surface an authenticated message that `_advanceVersionFrontier` dropped as an "older
    ///      duplicate" even though its record was still open. Callers invoke this only after their own
    ///      idempotency short-circuit has already ruled out a genuine re-delivery, so the event fires
    ///      exactly on the overshot-frontier case and never on normal LayerZero retries.
    function _alertDroppedAheadOfFrontier(
        StargateExecutorState storage self,
        uint256 chainId_,
        MsgType msgType_,
        bytes32 recordId_,
        uint64 stateVersion_
    ) internal {
        emit AuthenticatedMessageDroppedAheadOfFrontier(
            chainId_,
            uint8(msgType_),
            recordId_,
            stateVersion_,
            self.acknowledgedRemoteStateVersion[chainId_]
        );
    }

    /// @dev Add to the in-flight buckets. The transfer-staleness clock is armed on RECORD creation (per
    ///      record slot), not on bucket transitions, so this only moves value between buckets (§9 P2).
    function _addInFlight(
        StargateExecutorState storage self,
        uint256 chainId_,
        uint256 outboundSD_,
        uint256 returnSD_
    ) internal {
        self.outboundInFlight[chainId_] += outboundSD_;
        self.returnInFlight[chainId_] += returnSD_;
    }

    /// @dev Remove from the in-flight buckets (slot lifecycle is handled by the record resolve paths).
    function _removeInFlight(
        StargateExecutorState storage self,
        uint256 chainId_,
        uint256 outboundSD_,
        uint256 returnSD_
    ) internal {
        self.outboundInFlight[chainId_] -= outboundSD_;
        self.returnInFlight[chainId_] -= returnSD_;
    }

    /// @dev Finalize a return record and release its unresolved-transfer slot exactly once.
    function _finalizeReturn(
        StargateExecutorState storage self,
        uint256 chainId_,
        bytes32 requestId_,
        ReturnRecord storage rec_
    ) internal {
        rec_.finalized = true;
        _resolveCancelledClock(self, chainId_, rec_);
        if (rec_.noClockCounted) {
            // IL-8624: the last unclocked record is gone; lift the block iff it was the only reason for it.
            rec_.noClockCounted = false;
            uint32 left = --self.noClockReturnCount[chainId_];
            if (left == 0 && self.blockRaisedByNoClockReturn[chainId_]) {
                self.blockRaisedByNoClockReturn[chainId_] = false;
                if (!self.frontierRepairPending[chainId_]) self.chainBlocked[chainId_] = false;
                emit NoClockReturnBlockLifted(chainId_);
            }
        }
        if (rec_.pendingSlotArmed) {
            _resolvePendingSlot(self, chainId_, rec_.pendingSlot);
            rec_.pendingSlotArmed = false;
            rec_.slotCounted = false;
        } else if (rec_.slotCounted) {
            // Capacity was reserved at request time but no timestamp slot is currently held; give the
            // capacity back exactly once. Gated on `slotCounted` so a cancelled recall — whose capacity
            // was already returned — can never decrement a second time (audit M-2).
            rec_.slotCounted = false;
            uint256 count = self.pendingTransferCount[chainId_];
            if (count > 0) {
                unchecked {
                    self.pendingTransferCount[chainId_] = count - 1;
                }
            }
        }
        if (self.activeReturnRequest[chainId_] == requestId_) {
            delete self.activeReturnRequest[chainId_];
        }
    }

    /// @dev IL-8618 / IL-8624: raise the fail-closed block for a return record that owns value but has no staleness
    ///      slot, and count the record. Remembers whether this call (and not an earlier reason) set the block, so
    ///      the finalization of the last such record can lift it again. A block raised for another reason while
    ///      the record is open is not tracked per reason: the flag is reset there and only the timelocked
    ///      `forceSetSettled` lifts it.
    function _raiseNoClockBlock(
        StargateExecutorState storage self,
        uint256 chainId_,
        ReturnRecord storage rec_
    ) private {
        if (!rec_.noClockCounted) {
            rec_.noClockCounted = true;
            ++self.noClockReturnCount[chainId_];
        }
        if (!self.chainBlocked[chainId_]) self.blockRaisedByNoClockReturn[chainId_] = true;
        self.chainBlocked[chainId_] = true;
    }

    /// @dev IL-8621: a cancelled recall's first return leg (metadata or compose) landed, or the record was finalized
    ///      (rejection, force-resolve): drop one from the chain's cancelled count and clear the clock with the last
    ///      one. No-op for a record that is not holding a clock, and after a reset (`ADVANCE_STATE_FRONTIER`,
    ///      force-set, accepted approval) bumped the generation, so an older cancel never touches a newer clock.
    function _resolveCancelledClock(
        StargateExecutorState storage self,
        uint256 chainId_,
        ReturnRecord storage rec_
    ) internal {
        if (!rec_.cancelClockHeld) return;
        rec_.cancelClockHeld = false;
        uint32 count = self.cancelledRecallCount[chainId_];
        if (count == 0 || rec_.cancelGeneration != self.cancelledRecallGeneration[chainId_]) return;
        self.cancelledRecallCount[chainId_] = count - 1;
        if (count == 1) delete self.cancelledRecallPendingAt[chainId_];
    }

    /// @dev IL-8621: drop the chain's cancelled-recall clock and start a new generation.
    function _resetCancelledClock(StargateExecutorState storage self, uint256 chainId_) internal {
        delete self.cancelledRecallCount[chainId_];
        delete self.cancelledRecallPendingAt[chainId_];
        ++self.cancelledRecallGeneration[chainId_];
    }

    /// @dev Permissionless liveness escape for a recall on which NOTHING has moved between accounting
    ///      buckets: no authenticated `RETURN_STARTED` and no delivery compose. In that state the record
    ///      is a pure reservation — the recalled value is still counted in `settledRemoteBalance`, which
    ///      carries its own freshness gate — so handing back the request slot and the staleness slot is
    ///      accounting-neutral and cannot disarm a NAV gate that is protecting value. The cancel also keeps the
    ///      chain's cancelled-recall clock armed (IL-8621), so NAV stays gated until that clock clears.
    ///
    ///      Once metadata or the compose has landed the record OWNS value: metadata debits settled and
    ///      books `returnInFlight`, the compose books `pendingArrivalReserve`. The record's staleness slot
    ///      is then the only clock on that value, and releasing it permissionlessly would convert the
    ///      fail-closed transfer-staleness gate in `computeNavSD` into a fail-open one — the value would
    ///      keep being priced into NAV forever with no clock and no way back (audit
    ///      `permissionless_disarm_of_fail_closed_nav_staleness_gate`). That state is deliberately left to
    ///      the timelocked rescue (`applyForceResolve`), which is the only path that also removes the
    ///      value from the NAV buckets.
    /// @param self The executor state.
    /// @param chainId_ The remote chain whose active return request is cancelled.
    /// @param transferStalenessMax_ The transfer staleness bound `TRANSFER_STALENESS_MAX` (not the attestation
    ///        bound `STALENESS_MAX`): the request is stale once `createdAt + transferStalenessMax_` has passed.
    function cancelStaleReturn(
        StargateExecutorState storage self,
        uint256 chainId_,
        uint256 transferStalenessMax_
    ) public {
        bytes32 requestId = self.activeReturnRequest[chainId_];
        if (requestId == bytes32(0)) revert CrosschainErrors.NoActiveReturnRequest(chainId_);
        ReturnRecord storage rec = self.returnRecords[requestId];
        uint256 staleAt = uint256(rec.createdAt) + transferStalenessMax_;
        if (transferStalenessMax_ == 0 || block.timestamp <= staleAt) {
            revert CrosschainErrors.ReturnRequestNotStale(chainId_, rec.createdAt, staleAt);
        }
        if (rec.metadataArrived || rec.composeArrived) {
            revert CrosschainErrors.ReturnRequestValueMoved(chainId_, requestId);
        }
        rec.cancelled = true;
        delete self.activeReturnRequest[chainId_];
        // IL-8621: the dispatcher may already have bridged the recall; keep a staleness clock armed for the chain
        // (the oldest cancelled request's `createdAt`) until a leg, a rejection, a later approval or a reset.
        rec.cancelClockHeld = true;
        rec.cancelGeneration = self.cancelledRecallGeneration[chainId_];
        ++self.cancelledRecallCount[chainId_];
        uint64 oldestCancelled = self.cancelledRecallPendingAt[chainId_];
        if (oldestCancelled == 0 || rec.createdAt < oldestCancelled) {
            self.cancelledRecallPendingAt[chainId_] = rec.createdAt;
        }
        self.cancelledRecallVersion[chainId_] = self.acknowledgedRemoteStateVersion[chainId_];
        if (rec.pendingSlotArmed) {
            _resolvePendingSlot(self, chainId_, rec.pendingSlot);
            rec.pendingSlotArmed = false;
            rec.slotCounted = false;
        }
        _bumpAccountingEpoch(self, chainId_);
        emit ReturnRequestCancelled(chainId_, requestId);
    }

    /// @dev Anchor credit for a credit ALREADY added to `settledRemoteBalance` (IL-8578 / TP-H-02). Raises
    ///      `netPrincipal` by `credited_` and sets the anchor to `max(min(anchor + credited_, net), floor)`
    ///      (it may lower it), where `floor = ceil(settledAfter * 10_000 / (10_000 + bandBps))`.
    ///      The cap closes the recall / re-supply ratchet: the pro-rata recall debit leaves the anchor above
    ///      the net principal remaining whenever the bucket carries unrecognised yield, so a full-value
    ///      credit on re-supply would grow band headroom with no new capital. After any round trip the
    ///      anchor is at most `max(netPrincipal, the pre-recall anchor)`, up to one shared-decimal unit of
    ///      `Ceil` rounding per credit (a cycle costs two bridge round trips and an attestation to gain one
    ///      unit, so it is not economically exploitable). The floor keeps `settled` at or
    ///      below the band ceiling (`settled <= 1.2 * anchor`); it is the same minimum raise `_applyReturnDebit`
    ///      uses. It does NOT bound `settled` from below (IL-8792): on a `(settled 0, anchor R, net N > 0)`
    ///      pair a top-up `c` gives `(c, min(R, N) + c)`, which is below the band iff
    ///      `c < 4 * min(R, N)`; the windows were disjoint (pre-fix freeze) iff
    ///      `c * (1 + bigChangeBps / 10_000) < 0.8 * (min(R, N) + c)`, e.g. `c < 8/3 * min(R, N)` at 10%.
    ///      `approve` then treats that `settled` as no baseline (band alone, like zero, IL-8606), so an
    ///      approvable value always exists.
    ///      Inbound handler: no revert.
    function _creditAnchor(StargateExecutorState storage self, uint256 chainId_, uint256 credited_) private {
        uint256 net = self.netPrincipal[chainId_] + credited_;
        self.netPrincipal[chainId_] = net;
        uint256 anchor = self.anchorPrincipal[chainId_] + credited_;
        if (anchor > net) anchor = net;
        uint256 floor_ = Math.mulDiv(
            self.settledRemoteBalance[chainId_],
            10_000,
            10_000 + CrosschainConstants.ATTESTATION_ANCHOR_BAND_BPS,
            Math.Rounding.Ceil
        );
        if (anchor < floor_) anchor = floor_;
        self.anchorPrincipal[chainId_] = anchor;
        emit AttestationAnchorUpdated(chainId_, anchor);
        emit AttestationNetPrincipalUpdated(chainId_, net);
    }

    /// @dev Debits `settled` by the amount the dispatcher declared it sent and the anchor pro rata.
    ///      The pro-rata anchor debit assumes the recalled amount holds principal and unrecognised P&L in the
    ///      bucket's proportions. The dispatcher pays a recall out of `trackedIdle` only, so a return shorter
    ///      than the attested bucket leaves a residue that still carries the whole unrecognised remote loss;
    ///      once that loss puts the true value below the band floor and the residue is above
    ///      `ATTESTATION_ZERO_DUST_SD`, it cannot be attested down. The exit is `rejectAndBlockProposal` plus
    ///      `forceSetSettled` (IL-8585 / TP-M-07); operators attest known losses BEFORE recalling.
    ///      Residual anchor: (1) a debit that empties the bucket keeps a non-dust `remoteBalanceSD_` as the
    ///      anchor (IL-8606). (2) A later authenticated return at `settled == 0` (for example a second recall
    ///      opened after the first one was cancelled) recomputes the anchor from the reported balance, only
    ///      downwards and to zero at or below dust, so a stale residual cannot anchor a phantom attestation
    ///      (IL-9163).
    function _applyReturnDebit(
        StargateExecutorState storage self,
        uint256 chainId_,
        bytes32 requestId_,
        ReturnRecord storage rec_,
        uint256 amountSentSD_,
        uint256 remoteBalanceSD_
    ) internal returns (uint256 accountedDebitSD) {
        uint256 settled = self.settledRemoteBalance[chainId_];
        uint256 bounded = rec_.maxAccountedSD < settled ? rec_.maxAccountedSD : settled;
        accountedDebitSD = amountSentSD_ < bounded ? amountSentSD_ : bounded;
        self.settledRemoteBalance[chainId_] = settled - accountedDebitSD;
        // Accounting anchor pro-rata debit (IL-7967): a recall removes principal and unrecognised yield
        // in the proportion the settled bucket holds them, so the band headroom is preserved across a
        // partial recall and both reach zero together on a full recall — except a non-dust residual
        // reported by the dispatcher, which keeps the anchor (residual rule below). Rounds UP (Ceil) so the
        // anchor never over-states remaining principal — the conservative direction, since the band is measured
        // against it. Inbound handler: clamp, never revert; `settled != 0` guards the denominator (a
        // zero-settled chain has `accountedDebitSD == 0` and skips `Math.mulDiv` below; the residual rule for
        // that case is the `else if` branch, IL-9163).
        if (settled != 0 && accountedDebitSD != 0) {
            uint256 principal = self.anchorPrincipal[chainId_];
            uint256 principalDebit = Math.mulDiv(principal, accountedDebitSD, settled, Math.Rounding.Ceil);
            uint256 remaining = principalDebit > principal ? 0 : principal - principalDebit;
            uint256 settledAfter = settled - accountedDebitSD;
            // Band consistency (IL-7967 cycle 3). Ceil shrinks the anchor faster than the bucket, so the
            // pro-rata pair can land OUTSIDE the very band `approve` enforces. The band window and the
            // relative window are then disjoint and NO approvable value exists: `lastApprovedObservedAt`
            // can never be refreshed again and `computeNavSD` fails closed on `NavSettledStale`. Restore
            // the band by the MINIMUM raise — the smallest anchor for which `settledAfter` sits inside it,
            // `ceil(settledAfter * 10_000 / (10_000 + bandBps))`. NOT `settledAfter` itself: that adopts
            // an ATTESTED figure as principal and lets a 1-unit recall from the top of the band carry the
            // anchor to ~1.2x, compounding into the ratchet this ticket closes. The minimum
            // raise cannot: the pre-debit pair is band-legal, so `settledAfter <= settled <= principal *
            // (10_000 + bandBps) / 10_000` and the raised value is <= the pre-debit `principal` — the
            // anchor is non-increasing under debits (the residual rule below is capped to keep it so). It also
            // subsumes a floor at 1: with `remaining == 0` and `settledAfter != 0` the raise yields at least 1.
            // Inbound handler: clamp, never revert.
            uint256 bandBps = CrosschainConstants.ATTESTATION_ANCHOR_BAND_BPS;
            if (settledAfter > remaining && (settledAfter - remaining) * 10_000 > remaining * bandBps) {
                remaining = Math.mulDiv(settledAfter, 10_000, 10_000 + bandBps, Math.Rounding.Ceil);
            }
            // Residual anchor (IL-8606 / TP-M-28): a recall that empties the bucket while the dispatcher's
            // authenticated post-debit balance (`ReturnStarted.remoteBalanceSD`) still holds more than dust
            // (yield earned after the last attestation) keeps that residual as the anchor, so an ordinary
            // attestation can price it inside the band instead of leaving it orphaned behind a zero baseline.
            // `settled` itself is NOT credited: the residual enters NAV only once attested.
            if (settledAfter == 0 && remoteBalanceSD_ > CrosschainConstants.ATTESTATION_ZERO_DUST_SD) {
                // Capped at the pre-debit anchor: an honest residual (yield since the last attestation) never
                // exceeds it, and the cap keeps the anchor non-increasing under debits even if the reported
                // figure was inflated (e.g. a spot-manipulable allowlisted vault on a permissionless delivery).
                remaining = remoteBalanceSD_ < principal ? remoteBalanceSD_ : principal;
            }
            self.anchorPrincipal[chainId_] = remaining;
            emit AttestationAnchorUpdated(chainId_, remaining);
        } else if (settled == 0 && amountSentSD_ != 0) {
            // Later return at `settled == 0` (IL-9163): a return authenticated after the bucket was already
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
        // (`amountSentSD_`, authenticated by the transport), floored at zero, NOT by the settled delta. The
        // attester pair can lower `settled` while a recall is in flight, so the settled delta can be smaller
        // than the real return and would leave phantom units in `netPrincipal` that inflate the credit cap
        // round after round. Pro-rata anchor debit and band clamp above are unchanged.
        if (amountSentSD_ != 0) {
            uint256 net = self.netPrincipal[chainId_];
            net = amountSentSD_ > net ? 0 : net - amountSentSD_;
            self.netPrincipal[chainId_] = net;
            emit AttestationNetPrincipalUpdated(chainId_, net);
        }
        if (amountSentSD_ > accountedDebitSD) {
            emit ReturnDebitExceededAccountingBound(
                chainId_,
                requestId_,
                amountSentSD_,
                accountedDebitSD,
                amountSentSD_ - accountedDebitSD
            );
        }
    }

    /// @dev Arm a per-chain unresolved-transfer slot with the current timestamp and increment the count.
    ///      The per-chain cap (`MAX_PENDING_TRANSFERS_PER_CHAIN`) is enforced by the executor BEFORE any
    ///      creating call, so a free slot is guaranteed to exist here.
    function _armPendingSlot(StargateExecutorState storage self, uint256 chainId_) internal returns (uint8 slot) {
        uint256 max = CrosschainConstants.MAX_PENDING_TRANSFERS_PER_CHAIN;
        for (uint256 i; i < max; ++i) {
            if (self.pendingRecordCreatedAt[chainId_][i] == 0) {
                self.pendingRecordCreatedAt[chainId_][i] = SafeCast.toUint64(block.timestamp);
                unchecked {
                    ++self.pendingTransferCount[chainId_];
                }
                return uint8(i);
            }
        }
        // Unreachable: the cap gate guarantees a free slot. Fail closed rather than silently overwrite.
        revert CrosschainErrors.PendingTransfersCapReached(chainId_, max);
    }

    /// @dev Arm a slot if the pool has room, consuming one unit of capacity. Never reverts.
    function _tryArmPendingSlot(
        StargateExecutorState storage self,
        uint256 chainId_
    ) internal returns (uint8 slot, bool armed) {
        uint256 max = CrosschainConstants.MAX_PENDING_TRANSFERS_PER_CHAIN;
        for (uint256 i; i < max; ++i) {
            if (self.pendingRecordCreatedAt[chainId_][i] == 0) {
                self.pendingRecordCreatedAt[chainId_][i] = SafeCast.toUint64(block.timestamp);
                unchecked {
                    ++self.pendingTransferCount[chainId_];
                }
                return (uint8(i), true);
            }
        }
        return (0, false);
    }

    /// @dev Assign a timestamp slot to a recall whose capacity was already counted at request creation.
    ///      Never reverts; the caller keeps `slotCounted` set so the capacity is still released once.
    function _tryArmSlotForReservedReturn(
        StargateExecutorState storage self,
        uint256 chainId_
    ) internal returns (uint8 slot, bool armed) {
        uint256 max = CrosschainConstants.MAX_PENDING_TRANSFERS_PER_CHAIN;
        for (uint256 i; i < max; ++i) {
            if (self.pendingRecordCreatedAt[chainId_][i] == 0) {
                self.pendingRecordCreatedAt[chainId_][i] = SafeCast.toUint64(block.timestamp);
                return (uint8(i), true);
            }
        }
        return (0, false);
    }

    /// @dev Release a per-chain unresolved-transfer slot exactly once and decrement the count. Idempotent
    ///      against a double-release (a slot already 0 does not underflow the count).
    function _resolvePendingSlot(StargateExecutorState storage self, uint256 chainId_, uint8 slot_) internal {
        if (self.pendingRecordCreatedAt[chainId_][slot_] == 0) return;
        self.pendingRecordCreatedAt[chainId_][slot_] = 0;
        uint256 count = self.pendingTransferCount[chainId_];
        if (count > 0) {
            unchecked {
                self.pendingTransferCount[chainId_] = count - 1;
            }
        }
    }

    /// @dev The oldest occupied unresolved-transfer slot's timestamp for a chain (0 when none), used by
    ///      the NAV transfer-staleness gate. Bounded scan (cap is 16), safe in a view.
    function _oldestUnresolvedAt(
        StargateExecutorState storage self,
        uint256 chainId_
    ) internal view returns (uint64 oldest) {
        uint256 max = CrosschainConstants.MAX_PENDING_TRANSFERS_PER_CHAIN;
        for (uint256 i; i < max; ++i) {
            uint64 c = self.pendingRecordCreatedAt[chainId_][i];
            if (c != 0 && (oldest == 0 || c < oldest)) oldest = c;
        }
    }

    /// @notice The oldest unresolved-transfer timestamp for a chain (0 when none). Exposed so the executor
    ///         can reproduce a `inFlightSince`-style getter and monitors can read the staleness clock.
    function oldestUnresolvedTransferAt(
        StargateExecutorState storage self,
        uint256 chainId_
    ) public view returns (uint64) {
        return _oldestUnresolvedAt(self, chainId_);
    }

    /// @dev Bump a chain's accounting epoch and invalidate its sole active proposal (§9). Called where attested
    ///      value lands or is re-attributed: TRANSFER_SETTLED (incl. late credit), return legs (not a plain
    ///      order-(b) compose on a record that still holds its slot: `settled` still counts it), command ACK /
    ///      late-receipt adoption / abandon, stale-recall cancel, force-set, force-resolve (incl. frontier repair
    ///      and lane realign). NOT on an outbound send, a rejected return or a NACK (IL-8622). The proposal is
    ///      marked SUPERSEDED and `ProposalInvalidated` is emitted (IL-8472). Nothing is emitted when no proposal
    ///      is active.
    function _bumpAccountingEpoch(StargateExecutorState storage self, uint256 chainId_) internal {
        uint64 newEpoch;
        unchecked {
            newEpoch = ++self.accountingEpoch[chainId_];
        }
        uint256 pid = self.activeProposalId[chainId_];
        if (pid != 0) {
            self.proposals[pid].status = PROPOSAL_SUPERSEDED;
            self.activeProposalId[chainId_] = 0;
            emit ProposalInvalidated(chainId_, pid, newEpoch);
        }
    }
}

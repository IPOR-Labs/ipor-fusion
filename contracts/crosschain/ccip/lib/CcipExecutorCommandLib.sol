// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Command, CrosschainMessages} from "../../lib/CrosschainMessages.sol";
import {CcipMsgType} from "./CcipMessages.sol";
import {BusinessAction, CommandStatus, CommandResolution, CrosschainConstants} from "../../lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../lib/CrosschainErrors.sol";

struct CcipExecutorCommandState {
    mapping(bytes32 => uint256) destination;
    mapping(bytes32 => CommandStatus) status;
    mapping(bytes32 => Command) commands;
    mapping(uint256 => bytes32) active;
    mapping(uint256 => uint64) nextCommandSequence;
    mapping(uint256 => uint64) commandConfigEpoch;
    mapping(bytes32 => bool) advancesConfig;
    mapping(bytes32 => bool) cancelRequested;
    mapping(bytes32 => uint64) lastCancelAt;
}

/// @notice Why an inbound command receipt was ignored instead of applied.
/// @dev A receipt that reverted for a reason that never goes away would fail on the OffRamp forever.
///      Receipts are therefore always applied-or-ignored, never reverted, and the reason is surfaced as an
///      event for monitoring. A `COMMAND_ACK` carries the dispatcher's state version as evidence only
///      (IL-8257): it never touches the frontier, so it cannot hit the version gap. The only intended revert
///      on the dispatcher -> executor lane is the version gap in `acceptRemoteStateVersion`, which applies
///      to the value-moving `TRANSFER_SETTLED` / `RETURN_TRANSFER` responses and clears once the missing
///      response lands (IL-8496).
enum ReceiptIgnoreReason {
    NONE,
    UNKNOWN_COMMAND,
    WRONG_CHAIN,
    SEQUENCE_MISMATCH,
    ALREADY_RESOLVED,
    INVALID_RESOLUTION
}

library CcipExecutorCommandLib {
    error ActiveCommandExists(uint256 chainId, bytes32 commandId);
    error CommandNotFailed(bytes32 commandId);
    /// @notice The retry's effective gas limit is below the stored command's budget plus the pre-call allowance.
    error RetryGasBelowCommandBudget(bytes32 commandId, uint256 laneGas, uint256 requiredLaneGas);
    error UnknownCommand(bytes32 commandId);
    error CommandSequenceMismatch(uint64 expected, uint64 received);
    /// @notice Thrown when a retry is requested for a command whose CANCEL is still in flight.
    error CancelInFlight(uint256 chainId, bytes32 commandId);
    /// @notice The previous CANCEL_COMMAND for this command is younger than `CANCEL_COMMAND_COOLDOWN` (IL-8579).
    error CancelCooldown(uint256 chainId, bytes32 commandId, uint256 nextAllowedAt);
    /// @notice Thrown when the abandon rescue targets a chain whose command slot is already free.
    error NoStuckCommand(uint256 chainId);
    /// @notice Thrown when the abandon rescue executes before the command has expired on both chains.
    error CommandNotExpired(bytes32 commandId, uint256 abandonableAt);
    /// @notice Thrown when the realign executes against mirrors other than the ones it was armed against: an
    ///         authenticated receipt (or an abandon) moved the lane during the delay. Reschedule from the new state.
    error RealignStateMoved(
        uint256 chainId, uint64 expectedSequence, uint64 actualSequence, uint64 expectedEpoch, uint64 actualEpoch
    );
    // Mirrors of the executor's vault-shape errors. Declared in both places on purpose: the selector is
    // derived from the signature, so the revert data is identical and the executor's ABI is unchanged.
    error TooManyVaults(uint256 supplied, uint256 maximum);
    error InvalidVaultAddress(address vault);
    error DuplicateVault(address vault);
    /// @notice Mirror of the executor's error (raised here by `meterBalanceRequest`).
    error BalanceRequestOutstanding(uint256 chainId, uint64 requestedAt);
    /// @notice Mirror of the executor's error (raised here by `meterBalanceRequest`).
    error BalanceRequestCooldown(uint256 chainId, uint256 nextAllowedAt);

    /// @notice A command whose receipt can never arrive was terminally abandoned by the timelocked rescue.
    ///         Never expected in normal operation — alert on this.
    event CommandAbandoned(uint256 chainId, bytes32 commandId, uint64 sequence, bool sequenceConsumed);

    /// @notice A sequenced command (a business command or an allowlist update, `advancesConfig == true` with
    ///         `action == 0`) was built for sending to `dstChainId`.
    /// @dev CCIP counterpart of the Stargate executor's `CommandSent` (different fields, so a different topic0).
    event CommandSent(
        uint256 dstChainId,
        bytes32 commandId,
        uint64 sequence,
        uint8 action,
        bool advancesConfig,
        uint64 commandConfigEpoch
    );

    /// @notice An authenticated COMMAND_ACK receipt was applied to the command it names.
    /// @dev Emitted from `acknowledgeReceipt` only when the receipt was applied (reason `NONE`), so an ignored
    ///      receipt raises `CommandReceiptIgnored` instead. Unlike the receipt's bare acknowledgement it says how
    ///      the dispatcher resolved the command, so the ACK of a cancelled command is distinguishable from the ACK
    ///      of a succeeded one. A late receipt adopted for a command that no longer owned the slot additionally
    ///      emits `CommandReceiptAdopted`.
    ///      - `srcChainId`: the chain whose dispatcher sent the receipt.
    ///      - `sequence`: the command's sequence.
    ///      - `stateVersion`: the dispatcher's state version carried by the receipt (its remote state version
    ///        after the resolution).
    ///      - `valueDelta`: the value delta from the receipt, in the dispatcher's units, exactly as reported.
    ///      - `resolution`: the raw `CommandResolution` byte, `0` = SUCCEEDED (the action ran on the dispatcher),
    ///        `1` = CANCELLED (terminally cancelled, nothing applied), `2` = EXPIRED (cancel past the deadline:
    ///        the slot of a FAILED command was released, the sequence NOT consumed; also emits
    ///        `CommandExpiryReleased`).
    ///      - `commandConfigEpoch`: the executor's config epoch mirror for the chain AFTER the receipt was applied.
    event CommandAcknowledged(
        uint256 srcChainId,
        bytes32 commandId,
        uint64 sequence,
        uint64 stateVersion,
        int256 valueDelta,
        uint8 resolution,
        uint64 commandConfigEpoch
    );

    /// @notice A FAILED command was re-armed for a retry on `chainId`.
    event CommandRetryRequested(uint256 chainId, bytes32 commandId);

    /// @notice The dispatcher's authoritative config epoch differed from the executor's expectation and
    ///         the mirror was realigned to it. Never expected in normal operation — alert on this.
    event ConfigEpochResynced(uint256 chainId, uint64 expectedEpoch, uint64 dispatcherEpoch);

    /// @notice An authenticated receipt for a command that no longer owned the slot re-aligned the lane's
    ///         mirrors. `supersededCommandId` is the replacement it retired, or zero when the slot was
    ///         free. Never expected in normal operation — alert on this.
    event CommandReceiptAdopted(
        uint256 chainId, bytes32 commandId, uint64 sequence, uint64 dispatcherConfigEpoch, bytes32 supersededCommandId
    );

    /// @notice The receipt of the command a correct `sequenceConsumed = true` abandon freed the slot for
    ///         arrived late and refreshed the config epoch mirror (IL-8632). The sequence mirror is untouched
    ///         (the abandon already advanced it). A command that owns the slot at this point was stamped with
    ///         the previous epoch and is NACKed by the dispatcher: cancel it and send it again. Never expected in
    ///         normal operation: review the abandoned command's lane history.
    event LateReceiptEpochAdopted(uint256 chainId, uint64 sequence, uint64 previousEpoch, uint64 newEpoch);

    /// @notice A late receipt retired a replacement that was still PENDING (IL-8594, observability only). The
    ///         replacement can no longer execute; alert on this and review the abandoned command's lane history.
    event LateReceiptRetiredPendingReplacement(uint256 chainId, uint64 sequence, bytes32 retiredCommandId);
    /// @notice An authenticated `EXPIRED` receipt freed the slot of a FAILED command the dispatcher closed
    ///         past its deadline (IL-8594). The command is CANCELLED, the sequence mirror is unchanged (the
    ///         dispatcher did not consume it), so the next command reuses `sequence`.
    event CommandExpiryReleased(uint256 chainId, bytes32 commandId, uint64 sequence);

    /// @notice The timelocked realign set the lane's mirrors to declared values. Never expected in normal
    ///         operation — alert on this.
    event CommandLaneRealigned(
        uint256 chainId, uint64 previousSequence, uint64 newSequence, uint64 previousEpoch, uint64 newEpoch
    );

    // Mirrors of the executor's frontier events, so that under delegatecall the logs are indistinguishable
    // from the previously-inlined implementation (same emitter, same topics).
    event StaleRemoteBalanceIgnored(uint256 chainId, uint64 currentVersion, uint64 receivedVersion);
    /// @dev `balance` is the peer-reported accounted total (idle + queued + tracked positions on the remote
    ///      chain) and is not bounded against any local figure: it legitimately exceeds the bridged principal
    ///      by remote yield, so a cap here would either be vacuous or would make yield unrecognizable. It is
    ///      never written to NAV by this contract — evidence for the attester pair only (see the emit site's
    ///      comment). A proposal built from it is bounded by `CcipExecutorAttestationLib.approve`: `±bigChangeBps`
    ///      of `settledRemoteBalance` and the `ATTESTATION_ANCHOR_BAND_BPS` band around the accounting anchor; from
    ///      a zero bucket a non-zero proposal only within the band of a non-zero anchor (IL-8606); a zero proposal
    ///      from a zero or dust bucket skips both bounds.
    event RemoteBalanceUpdated(uint256 chainId, uint256 balance, uint64 stateVersion);

    /// @notice Mirror of the executor's event (delegatecalled log is indistinguishable).
    event DispatcherReady(uint256 chainId);

    /// @notice Advance the contiguous remote-state frontier by exactly one; revert on a gap.
    /// @dev Called ONLY for the value-moving responses `TRANSFER_SETTLED` and `RETURN_TRANSFER`, the only
    ///      ones that bump the dispatcher's `stateVersion` (IL-8257). Value-neutral responses
    ///      (`BALANCE_REPORT`, `COMMAND_ACK`) go through `recordRemoteBalanceEvidence` and must never move
    ///      the frontier: with CCIP 2.0 reordering, a report carrying `V+1` can overtake the still
    ///      in-transit `TRANSFER_SETTLED V+1`, and advancing on it would drop the settle as stale and lose
    ///      its credit.
    /// @dev CCIP does not deliver the dispatcher's responses in order: on CCIP 2.0 the OnRamp ignores
    ///      `allowOutOfOrderExecution = false` and `OffRamp.execute` is permissionless with no per-sender
    ///      ordering, so a later response can execute before an earlier one (IL-8496). A gap therefore
    ///      REVERTS `StateVersionGap`, as `StargateExecutorAccountingLib._advanceVersionFrontier` does: the OffRamp
    ///      records the message as FAILURE with all of its effects rolled back (a token-bearing
    ///      `RETURN_TRANSFER` keeps its tokens in the pool), and anyone re-executes it through
    ///      `OffRamp.execute` once the missing version has landed. The frontier stays "every version up to
    ///      here has been applied", which the proposal, force-set and frontier-repair bindings rely on.
    ///
    ///      Reordering alone does not fail NAV closed: a response still undelivered is the same state as one
    ///      still in flight, which the per-operation buckets and their staleness clocks already cover. A
    ///      version that never lands (a response dropped with `scheduleSkipStuckResponse`) leaves every
    ///      later response failing on the OffRamp until the timelocked `ADVANCE_FRONTIER` rescue moves past
    ///      it; meanwhile an honest attester cannot propose (the dispatcher's `observation().stateVersion`
    ///      is ahead of this frontier) and the chain fails closed through attestation and transfer
    ///      staleness. Both versioned handlers consume their version before any ignore exit on their payload, so
    ///      an ignored response never leaves a gap of its own (only the executor's token-shape check of
    ///      `TRANSFER_SETTLED`, which the dispatcher never sends with tokens, runs before it).
    ///
    ///      Lives here rather than on the executor for EIP-170 headroom.
    function acceptRemoteStateVersion(
        mapping(uint256 => uint64) storage lastRemoteStateVersion_,
        uint256 chainId_,
        uint256 remoteBalance_,
        uint64 stateVersion_
    ) public {
        uint64 current = lastRemoteStateVersion_[chainId_];
        if (stateVersion_ <= current) {
            emit StaleRemoteBalanceIgnored(chainId_, current, stateVersion_);
            return;
        }
        if (stateVersion_ != current + 1) {
            revert CrosschainErrors.StateVersionGap(chainId_, current + 1, stateVersion_);
        }
        lastRemoteStateVersion_[chainId_] = stateVersion_;
        // The dispatcher report is evidence for off-chain attesters, never an authoritative NAV write.
        emit RemoteBalanceUpdated(chainId_, remoteBalance_, stateVersion_);
    }

    /// @notice Record the balance and state version carried by a value-neutral response as evidence.
    /// @dev Used for `BALANCE_REPORT` and `COMMAND_ACK` (IL-8257). It only emits `RemoteBalanceUpdated`: it
    ///      never reverts and never writes the frontier, so these responses can neither gap nor advance it,
    ///      whatever order CCIP delivers them in, and a `COMMAND_ACK` ahead of a still in-transit value
    ///      response applies instead of failing on the OffRamp. The reported balance is evidence for the
    ///      attester pair only, never a NAV write.
    function recordRemoteBalanceEvidence(uint256 chainId_, uint256 remoteBalance_, uint64 stateVersion_) public {
        emit RemoteBalanceUpdated(chainId_, remoteBalance_, stateVersion_);
    }

    /// @notice Shape-only validation of a tracked-position vault list (bounded, nonzero, deduplicated).
    /// @dev Lives here rather than on the executor purely for EIP-170 headroom.
    function validateVaultShape(address[] calldata vaults_) public pure {
        uint256 length = vaults_.length;
        if (length > CrosschainConstants.MAX_TRACKED_POSITION_VAULTS) {
            revert TooManyVaults(length, CrosschainConstants.MAX_TRACKED_POSITION_VAULTS);
        }
        for (uint256 i; i < length; ++i) {
            address vault = vaults_[i];
            if (vault == address(0)) revert InvalidVaultAddress(vault);
            for (uint256 j; j < i; ++j) {
                if (vaults_[j] == vault) revert DuplicateVault(vault);
            }
        }
    }

    /// @notice Refuses a RETRY_COMMAND whose delivery gas cannot cover the stored command's budget (IL-8625).
    /// @dev The retry re-runs the stored command with its ORIGINAL `minExecutionGas`. If the route policy was lowered
    ///      since, a retry sent at the lower policy would revert below the budget on every delivery, so it is not sent.
    ///      The retry does not store the payload again, but the check is the conservative one (the same pre-call work
    ///      as the original send). Giving a retry MORE gas than the original is a timelocked route-policy raise
    ///      (`syncRoutePolicy`) before the retry: CCIP delivers exactly the policy and a manual execution of a retry
    ///      that was NACKed does not exist (a NACKed retry is a successful OffRamp execution).
    /// @param laneGas_ The retry message's effective gas limit (`CcipSendLib.commandGasLimit`).
    function requireRetryGas(
        CcipExecutorCommandState storage self,
        mapping(bytes32 id => uint32 words) storage payloadWords_,
        bytes32 id_,
        uint256 laneGas_
    ) public view {
        uint256 required =
            CrosschainMessages.laneGasFor(self.commands[id_].minExecutionGas, payloadWords_[id_], false);
        if (laneGas_ < required) revert RetryGasBelowCommandBudget(id_, laneGas_, required);
    }

    function initializeRoute(CcipExecutorCommandState storage self, uint256 chainId_) public {
        if (self.commandConfigEpoch[chainId_] == 0) self.commandConfigEpoch[chainId_] = 1;
    }

    /// @dev `markDispatcherReady` body (EIP-170): list the chain once, flag it ready, start its command-lane epoch.
    function markDispatcherReady(
        CcipExecutorCommandState storage self,
        mapping(uint256 => bool) storage hasDispatcher_,
        uint256[] storage dispatcherChainIds_,
        uint256 chainId_
    ) public {
        if (!hasDispatcher_[chainId_]) dispatcherChainIds_.push(chainId_);
        hasDispatcher_[chainId_] = true;
        initializeRoute(self, chainId_);
        emit DispatcherReady(chainId_);
    }

    /// @dev `requestRemoteBalance` metering (IL-8579; body here for EIP-170): at most one outstanding request per
    ///      chain (expires after `balanceStalenessMax_`) and `BALANCE_REQUEST_COOLDOWN` between two requests.
    function meterBalanceRequest(
        mapping(uint256 => uint64) storage lastBalanceRequestAt_,
        mapping(uint256 => bool) storage balanceRequestOutstanding_,
        uint256 chainId_,
        uint256 balanceStalenessMax_
    ) public {
        uint64 last = lastBalanceRequestAt_[chainId_];
        if (balanceRequestOutstanding_[chainId_] && block.timestamp < uint256(last) + balanceStalenessMax_) {
            revert BalanceRequestOutstanding(chainId_, last);
        }
        if (last != 0 && block.timestamp < uint256(last) + CrosschainConstants.BALANCE_REQUEST_COOLDOWN) {
            revert BalanceRequestCooldown(chainId_, uint256(last) + CrosschainConstants.BALANCE_REQUEST_COOLDOWN);
        }
        lastBalanceRequestAt_[chainId_] = uint64(block.timestamp);
        balanceRequestOutstanding_[chainId_] = true;
    }

    /// @param nonce The command nonce.
    /// @param laneGas The effective delivery gas of the message (`CcipSendLib.commandGasLimit`).
    /// @param extra The `extra` element of the stored `(type, command, extra)` payload (empty for a COMMAND, the
    ///        encoded vault update for an UPDATE_VAULTS); its length is part of the dispatcher's pre-check storage
    ///        work.
    /// @param requestedBudget The manager's `Command.minExecutionGas`: 0 = none; otherwise it must not exceed the
    ///        derived budget (CCIP delivers exactly the route gas; more needs a timelocked policy raise) nor
    ///        `MAX_COMMAND_EXECUTION_GAS`. The derived budget is what is stamped.
    struct BuildParams {
        address executor;
        uint256 chainId;
        uint8 action;
        bytes actionData;
        bool advancesConfig;
        uint256 nonce;
        uint256 laneGas;
        bytes extra;
        uint256 requestedBudget;
    }

    function build(
        CcipExecutorCommandState storage self,
        mapping(bytes32 id => uint32 words) storage payloadWords_,
        BuildParams memory p_
    )
        public
        returns (Command memory command_)
    {
        uint256 chainId_ = p_.chainId;
        bytes32 current = self.active[chainId_];
        if (current != bytes32(0)) revert ActiveCommandExists(chainId_, current);
        // The id carries the command's expiry (IL-8255); see `CrosschainMessages.stampCommandId`.
        bytes32 id = CrosschainMessages.stampCommandId(
            keccak256(abi.encode(p_.executor, chainId_, "CCIP_COMMAND", p_.nonce))
        );
        command_ = Command({
            commandId: id,
            sequence: self.nextCommandSequence[chainId_],
            commandConfigEpoch: self.commandConfigEpoch[chainId_],
            action: p_.action,
            minExecutionGas: 0,
            actionData: p_.actionData
        });
        // The dispatcher stores exactly `abi.encode(type, command, extra)`; the budget field is fixed-size, so the
        // word count is the same before and after it is set.
        uint256 words = CrosschainMessages.payloadWords(
            abi.encode(p_.advancesConfig ? CcipMsgType.UPDATE_VAULTS : CcipMsgType.COMMAND, command_, p_.extra).length
        );
        uint64 budget = CrosschainMessages.commandGasBudget(p_.laneGas, words, false);
        // The STAMPED budget is bounded too (IL-8625): a route policy above the cap would otherwise stamp a budget the
        // Ethereum transaction gas cap (EIP-7825) can never deliver.
        if (budget > CrosschainConstants.MAX_COMMAND_EXECUTION_GAS) {
            revert CrosschainErrors.CommandBudgetAboveMax(budget, CrosschainConstants.MAX_COMMAND_EXECUTION_GAS);
        }
        if (p_.requestedBudget != 0) {
            if (p_.requestedBudget > CrosschainConstants.MAX_COMMAND_EXECUTION_GAS) {
                revert CrosschainErrors.CommandBudgetAboveMax(
                    p_.requestedBudget, CrosschainConstants.MAX_COMMAND_EXECUTION_GAS
                );
            }
            if (p_.requestedBudget > budget) revert CrosschainErrors.CommandBudgetAboveLane(p_.requestedBudget, budget);
        }
        command_.minExecutionGas = budget;
        self.commands[id] = command_;
        payloadWords_[id] = uint32(words);
        self.destination[id] = chainId_;
        self.status[id] = CommandStatus.PENDING;
        self.advancesConfig[id] = p_.advancesConfig;
        self.active[chainId_] = id;
        emit CommandSent(chainId_, id, command_.sequence, p_.action, p_.advancesConfig, command_.commandConfigEpoch);
    }

    /// @dev `cancel_` marks the cancel path. A cancel is terminal: once issued, the dispatcher resolves
    ///      the command as CANCELLED and drops any later retry, so a retry racing an in-flight cancel can
    ///      only misreport the outcome. Reject the retry rather than clearing the flag
    ///      (audit `config_epoch_desync_via_retry_clearing_in_flight_cancel`).
    function requireFailed(CcipExecutorCommandState storage self, uint256 chainId_, bytes32 id_, bool cancel_) public {
        if (
            self.active[chainId_] != id_ || self.destination[id_] != chainId_
                || self.status[id_] != CommandStatus.FAILED
        ) revert CommandNotFailed(id_);
        if (cancel_) {
            // IL-8579: a repeat is allowed (a lost cancel must be re-sendable) but metered, each send costs a fee.
            uint256 last = self.lastCancelAt[id_];
            if (last != 0 && block.timestamp < last + CrosschainConstants.CANCEL_COMMAND_COOLDOWN) {
                revert CancelCooldown(chainId_, id_, last + CrosschainConstants.CANCEL_COMMAND_COOLDOWN);
            }
            self.lastCancelAt[id_] = uint64(block.timestamp);
            self.cancelRequested[id_] = true;
        } else {
            if (self.cancelRequested[id_]) revert CancelInFlight(chainId_, id_);
            // IL-8625: a retry of a command past its deadline can only end in a NACK (the dispatcher refuses an
            // expired command before running it): refuse it instead of paying the fee. The manager's CANCEL is the
            // exit (the EXPIRED receipt).
            if (block.timestamp > CrosschainMessages.commandDeadline(id_)) {
                revert CrosschainErrors.CommandExpired(id_);
            }
        }
    }

    /// @notice Decode and apply a raw authenticated COMMAND_ACK payload. NEVER reverts.
    /// @dev The decode lives here rather than on the executor purely for EIP-170 headroom: the executor
    ///      runs within a few hundred bytes of the limit and the library has ample room.
    /// @return reason `NONE` when the receipt was applied, otherwise why it was ignored.
    /// @return commandId The command the receipt resolves.
    /// @return sequence The command's sequence.
    /// @return remoteBalance The dispatcher's reported accounted balance (evidence only, never NAV).
    /// @return stateVersion The dispatcher's state version after the resolution.
    function acknowledgeReceipt(CcipExecutorCommandState storage self, uint256 chainId_, bytes memory data_)
        public
        returns (
            ReceiptIgnoreReason reason,
            bytes32 commandId,
            uint64 sequence,
            uint256 remoteBalance,
            uint64 stateVersion
        )
    {
        uint64 dispatcherConfigEpoch;
        uint8 resolution;
        int256 valueDelta;
        (commandId, sequence, valueDelta, remoteBalance, stateVersion, dispatcherConfigEpoch, resolution) =
            abi.decode(data_, (bytes32, uint64, int256, uint256, uint64, uint64, uint8));
        reason = acknowledge(self, chainId_, commandId, sequence, resolution, dispatcherConfigEpoch);
        if (reason == ReceiptIgnoreReason.NONE) {
            // Reuse the local for the mirror as applied (stack depth); the receipt's own epoch is spent.
            dispatcherConfigEpoch = self.commandConfigEpoch[chainId_];
            emit CommandAcknowledged(
                chainId_, commandId, sequence, stateVersion, valueDelta, resolution, dispatcherConfigEpoch
            );
        }
    }

    /// @notice Apply an authenticated ACK receipt. NEVER reverts (see `ReceiptIgnoreReason`).
    /// @dev `EXPIRED` (IL-8594) is handled before everything else that moves state: see the branch below. An ignored
    ///      `EXPIRED` receipt reports `ALREADY_RESOLVED`.
    /// @dev The receipt states how the dispatcher resolved the command and what its `commandConfigEpoch` is
    ///      afterwards. Both are taken from the receipt, never inferred from `cancelRequested`: a cancel
    ///      and a retry can be in flight simultaneously, so the local flag is ambiguous by the time the
    ///      resolution lands and reading it desynced the epoch mirrors permanently. Mirroring the
    ///      authoritative value also makes any divergence self-healing instead of bricking the lane, which
    ///      matters here because this handler must never revert (see `ReceiptIgnoreReason`).
    /// @return reason `NONE` when the receipt was applied, otherwise why it was ignored.
    /// @param resolution_ The raw `CommandResolution` byte from the receipt. Validated here rather than at
    ///        the call site so an out-of-range value is ignored, never decoded into a bogus enum.
    function acknowledge(
        CcipExecutorCommandState storage self,
        uint256 chainId_,
        bytes32 id_,
        uint64 sequence_,
        uint8 resolution_,
        uint64 dispatcherConfigEpoch_
    ) public returns (ReceiptIgnoreReason reason) {
        if (resolution_ > uint8(type(CommandResolution).max)) {
            return ReceiptIgnoreReason.INVALID_RESOLUTION;
        }
        if (self.destination[id_] == 0) return ReceiptIgnoreReason.UNKNOWN_COMMAND;
        if (self.destination[id_] != chainId_) return ReceiptIgnoreReason.WRONG_CHAIN;
        Command storage stored = self.commands[id_];
        if (stored.sequence != sequence_) return ReceiptIgnoreReason.SEQUENCE_MISMATCH;
        if (resolution_ == uint8(CommandResolution.EXPIRED)) {
            // `EXPIRED` is the dispatcher closing a command WITHOUT consuming its sequence, so it frees the slot
            // only for the very command that owns it as FAILED, never moves a mirror and never reaches
            // `_adoptLateReceipt` (which would treat it as a consumed sequence). Any other holder (a replacement,
            // a PENDING/terminal command, a free slot) leaves the receipt ignored; the reported reason is
            // `ALREADY_RESOLVED` for all of them (no dedicated reason, to spare executor bytes).
            if (self.active[chainId_] != id_ || self.status[id_] != CommandStatus.FAILED) {
                return ReceiptIgnoreReason.ALREADY_RESOLVED;
            }
            self.status[id_] = CommandStatus.CANCELLED;
            delete self.active[chainId_];
            emit CommandExpiryReleased(chainId_, id_, sequence_);
            return ReceiptIgnoreReason.NONE;
        }
        // The slot clear below is unconditional, so the receipt must be shown to belong to the command
        // that currently owns the slot. A receipt for a command that no longer owns it is handled
        // separately: it may still carry counters this executor has not accounted for, and it must never be
        // applied AS the replacement's own resolution. It may still RETIRE that replacement when the
        // dispatcher has already consumed its sequence — see `_adoptLateReceipt` (IL-7970).
        if (self.active[chainId_] != id_) {
            return _adoptLateReceipt(self, chainId_, id_, sequence_, resolution_, dispatcherConfigEpoch_);
        }
        CommandStatus current = self.status[id_];
        // SUCCEEDED / CANCELLED are terminal: a redelivered ACK is a duplicate and must be a no-op, never
        // a revert. FAILED is accepted because a retry that finally succeeds ACKs a command the executor
        // still has marked FAILED.
        if (current != CommandStatus.PENDING && current != CommandStatus.FAILED) {
            return ReceiptIgnoreReason.ALREADY_RESOLVED;
        }
        bool cancelled = resolution_ == uint8(CommandResolution.CANCELLED);
        self.status[id_] = cancelled ? CommandStatus.CANCELLED : CommandStatus.SUCCEEDED;
        delete self.active[chainId_];
        ++self.nextCommandSequence[chainId_];
        // A cancel ACK advances the command sequence, but the dispatcher applied nothing, so its
        // epoch is unchanged. Mirror whatever the dispatcher reports and surface any disagreement.
        uint64 expectedEpoch = (!cancelled && self.advancesConfig[id_])
            ? self.commandConfigEpoch[chainId_] + 1
            : self.commandConfigEpoch[chainId_];
        if (dispatcherConfigEpoch_ != expectedEpoch) {
            emit ConfigEpochResynced(chainId_, expectedEpoch, dispatcherConfigEpoch_);
        }
        self.commandConfigEpoch[chainId_] = dispatcherConfigEpoch_;
        return ReceiptIgnoreReason.NONE;
    }

    /// @dev A receipt for a command this executor built for this chain at this sequence (the identity
    ///      checks above have already established that), but which no longer owns the slot. It is authenticated
    ///      dispatcher state: the dispatcher resolved `sequence_` and so advanced its own counter — its
    ///      only two writers of `nextCommandSequence`, `CcipCrosschainDispatcher._completeCommand` and
    ///      `_cancelCommand`, both `++` it (`_cancelCommand` only before the deadline; its `EXPIRED` receipt
    ///      never reaches this path) — and it reports its `commandConfigEpoch` as of AFTER that resolution.
    ///      At or above the mirror the receipt therefore carries facts the mirror has not accounted for
    ///      (the abandon that freed the slot declared them from no observation), and they are adopted.
    ///      Below the mirror it is a transport duplicate or a receipt the abandon already accounted for,
    ///      and it stays ignored, except that the receipt for exactly `mirror - 1` refreshes the config
    ///      epoch mirror when its epoch is newer, whether or not a later command owns the slot (IL-8632). This
    ///      path only ever moves the sequence mirror UP. `realign` is the one writer here that can lower it.
    ///
    ///      A replacement occupying the slot with `sequence <= sequence_` can never execute: the
    ///      dispatcher's counter is strictly monotonic and already past that sequence, so its COMMAND
    ///      reverts `InvalidSequence` from here on. Retry and cancel cannot rescue it either — which error
    ///      they raise depends on whether the dispatcher ever stored the replacement (`CommandNotFailed`
    ///      when it did not, `InvalidSequence` when it did and the delivery NACKed; a cancel past the deadline
    ///      closes it without a receipt, IL-8594), and in either case this executor cannot build them once the
    ///      slot is cleared (`requireFailed`). It is superseded (CANCELLED, slot freed) rather than left for a
    ///      second timelocked abandon.
    ///
    ///      NEVER reverts: every branch returns, the storage writes cannot revert, and `sequence_ + 1`
    ///      cannot wrap — a receipt at `type(uint64).max` never exists, because the dispatcher's own
    ///      checked `++nextCommandSequence` would have reverted before producing it.
    function _adoptLateReceipt(
        CcipExecutorCommandState storage self,
        uint256 chainId_,
        bytes32 id_,
        uint64 sequence_,
        uint8 resolution_,
        uint64 dispatcherConfigEpoch_
    ) private returns (ReceiptIgnoreReason) {
        uint64 nextSequence = self.nextCommandSequence[chainId_];
        if (sequence_ < nextSequence) {
            // The receipt of the command a correct `sequenceConsumed = true` abandon just accounted for
            // (`sequence_ == nextSequence - 1`) is the only authenticated source of the dispatcher's config
            // epoch after that command (an UPDATE_VAULTS advances it), and the abandon cannot carry it. It
            // refreshes the epoch mirror only; the sequence was already advanced (IL-8632). It does so even when
            // a command built after the abandon owns the slot: that command carries the older mirror, which the
            // dispatcher (whose epoch only grows) has already passed, so it is NACKed whatever happens here, and
            // a receipt ignored now is never delivered again. The slot is left alone: that command still needs
            // its own NACK and CANCEL (or EXPIRED) receipt. Any older receipt or an epoch that is not newer
            // stays ignored, so a transport duplicate of an applied receipt is a no-op.
            uint64 previousEpoch = self.commandConfigEpoch[chainId_];
            if (sequence_ + 1 != nextSequence || dispatcherConfigEpoch_ <= previousEpoch) {
                return ReceiptIgnoreReason.ALREADY_RESOLVED;
            }
            self.commandConfigEpoch[chainId_] = dispatcherConfigEpoch_;
            emit LateReceiptEpochAdopted(chainId_, sequence_, previousEpoch, dispatcherConfigEpoch_);
            return ReceiptIgnoreReason.NONE;
        }
        bytes32 superseded = self.active[chainId_];
        if (superseded != bytes32(0) && self.commands[superseded].sequence <= sequence_) {
            if (self.status[superseded] == CommandStatus.PENDING) {
                emit LateReceiptRetiredPendingReplacement(chainId_, sequence_, superseded);
            }
            self.status[superseded] = CommandStatus.CANCELLED;
            delete self.active[chainId_];
        } else {
            superseded = bytes32(0);
        }
        self.status[id_] =
            resolution_ == uint8(CommandResolution.CANCELLED) ? CommandStatus.CANCELLED : CommandStatus.SUCCEEDED;
        uint64 previousEpoch = self.commandConfigEpoch[chainId_];
        unchecked {
            self.nextCommandSequence[chainId_] = sequence_ + 1;
        }
        self.commandConfigEpoch[chainId_] = dispatcherConfigEpoch_;
        if (dispatcherConfigEpoch_ != previousEpoch) {
            emit ConfigEpochResynced(chainId_, previousEpoch, dispatcherConfigEpoch_);
        }
        emit CommandReceiptAdopted(chainId_, id_, sequence_, dispatcherConfigEpoch_, superseded);
        return ReceiptIgnoreReason.NONE;
    }

    /// @notice Set the command-lane mirrors to the dispatcher's counters as observed by the rescue admin.
    /// @dev The one writer here that can move `nextCommandSequence` DOWN. Needed because an executor whose mirror
    ///      ran ahead — a `sequenceConsumed = true` abandon for a command the dispatcher never resolved —
    ///      stamps sequences the dispatcher will never accept, the dispatcher advances only by executing
    ///      the sequence it expects, and every other writer of this mirror only ever raises it
    ///      (`acknowledge` and `abandon` add one, `_adoptLateReceipt` writes `sequence + 1` under a
    ///      `sequence >= mirror` guard). Without this the state is terminal on a non-upgradeable pair.
    ///
    ///      It writes belief, not value: a wrong figure in either direction produces `InvalidSequence`
    ///      reverts or `InvalidConfigEpoch` NACKs on the dispatcher and is corrected by running this again
    ///      or by the next adopted receipt; it cannot make the dispatcher execute anything the manager did
    ///      not author. Both figures are read from the dispatcher's public `nextCommandSequence()` /
    ///      `commandConfigEpoch()` getters, so the declaration is made against observed state.
    ///
    ///      A free slot is required so no command is left stamped with a sequence the mirror no longer
    ///      stands behind — abandon first. That requirement is checked HERE, at execute time, and
    ///      deliberately not at schedule time, so the abandon and the realign can be scheduled in the same
    ///      block and executed back to back after a single delay (IL-7970).
    ///
    ///      `arg_` is `(expectedEpoch << 192) | (expectedSequence << 128) | (newEpoch << 64) | newSequence`. The
    ///      write only applies to the mirrors it was armed against: an authenticated ACK that lands during the
    ///      delay advances them and frees the slot, and applying the old snapshot then would roll the lane
    ///      backwards. The expected pair is therefore compared with the live mirrors and a mismatch reverts
    ///      `RealignStateMoved`; the admin reschedules from the new state. When an `ABANDON_COMMAND` armed in
    ///      the same batch runs first, the expected pair is the state AFTER it (sequence + 1 if it declares the
    ///      sequence consumed).
    function realign(CcipExecutorCommandState storage self, uint256 chainId_, uint256 arg_) public {
        bytes32 activeId = self.active[chainId_];
        if (activeId != bytes32(0)) revert ActiveCommandExists(chainId_, activeId);
        uint64 newSequence = uint64(arg_);
        uint64 newEpoch = uint64(arg_ >> 64);
        uint64 previousSequence = self.nextCommandSequence[chainId_];
        uint64 previousEpoch = self.commandConfigEpoch[chainId_];
        uint64 expectedSequence = uint64(arg_ >> 128);
        uint64 expectedEpoch = uint64(arg_ >> 192);
        if (previousSequence != expectedSequence || previousEpoch != expectedEpoch) {
            revert RealignStateMoved(chainId_, expectedSequence, previousSequence, expectedEpoch, previousEpoch);
        }
        self.nextCommandSequence[chainId_] = newSequence;
        self.commandConfigEpoch[chainId_] = newEpoch;
        emit CommandLaneRealigned(chainId_, previousSequence, newSequence, previousEpoch, newEpoch);
    }

    /// @notice Apply an authenticated NACK receipt. NEVER reverts (see `ReceiptIgnoreReason`).
    /// @dev A command that fails again after `retryCommand` produces a SECOND NACK for the same id while
    ///      the executor status is already FAILED. Treating that as a duplicate no-op keeps the receipt
    ///      applied-or-ignored; reverting here would fail it on the OffRamp forever (audit C-1).
    /// @return reason `NONE` when the receipt was applied, otherwise why it was ignored.
    function fail(CcipExecutorCommandState storage self, uint256 chainId_, bytes32 id_, uint64 sequence_)
        public
        returns (ReceiptIgnoreReason reason)
    {
        if (self.destination[id_] == 0) return ReceiptIgnoreReason.UNKNOWN_COMMAND;
        if (self.destination[id_] != chainId_) return ReceiptIgnoreReason.WRONG_CHAIN;
        Command storage stored = self.commands[id_];
        if (stored.sequence != sequence_) return ReceiptIgnoreReason.SEQUENCE_MISMATCH;
        CommandStatus current = self.status[id_];
        if (current == CommandStatus.FAILED) return ReceiptIgnoreReason.ALREADY_RESOLVED; // repeat NACK
        if (current != CommandStatus.PENDING) return ReceiptIgnoreReason.ALREADY_RESOLVED;
        self.status[id_] = CommandStatus.FAILED;
        return ReceiptIgnoreReason.NONE;
    }

    /// @notice Target vault of the DEPOSIT stored as `id_` (0 for any other action or an unknown id).
    /// @dev Read through `CcipCrosschainExecutor.commandDepositTarget` by the command fuse, which re-checks a retried
    ///      DEPOSIT's target against the vault's REMOTE_VAULT substrates (IL-8600 follow-up). Lives here, not on the
    ///      executor, for EIP-170 headroom.
    function depositTarget(CcipExecutorCommandState storage self, bytes32 id_) public view returns (address vault) {
        Command storage c = self.commands[id_];
        if (c.action == uint8(BusinessAction.DEPOSIT)) {
            (vault,,) = CrosschainMessages.decodeDepositAction(c.actionData);
        }
    }

    /// @notice Re-arm a FAILED command so a retry that fails again produces a fresh, applicable NACK.
    /// @dev Called by `retryCommand` on the executor through `requireRetryGasAndMarkRetrying`, after the IL-8625
    ///      gas check. Without this the retry's NACK would always be seen as a duplicate and the operator would
    ///      lose the FAILED/PENDING signal.
    function markRetrying(CcipExecutorCommandState storage self, bytes32 id_) public {
        self.status[id_] = CommandStatus.PENDING;
        emit CommandRetryRequested(self.destination[id_], id_);
    }

    /// @dev `requireRetryGas` then `markRetrying`, one library call from `retryCommand` (EIP-170).
    function requireRetryGasAndMarkRetrying(
        CcipExecutorCommandState storage self,
        mapping(bytes32 id => uint32 words) storage payloadWords_,
        bytes32 id_,
        uint256 laneGas_
    ) public {
        requireRetryGas(self, payloadWords_, id_, laneGas_);
        markRetrying(self, id_);
    }

    /// @notice Terminal exit for a command whose receipt can never arrive, freeing the chain's slot.
    /// @dev Mirrors `StargateExecutorAccountingLib._abandonCommand` (audit
    ///      `no_recovery_path_for_stuck_pending_command_bricks_command_lane`). `active[chainId]` is
    ///      cleared nowhere but the `acknowledge` path and here, and `build` refuses while it is set, so a
    ///      receipt that the lane never applies froze every later command for that chain. On this
    ///      transport a receipt is *ignored*, not retried — `acknowledgeReceipt` never reverts and the
    ///      executor emits `CommandReceiptIgnored` — so any `SEQUENCE_MISMATCH`/`UNKNOWN_COMMAND`/`WRONG_CHAIN`
    ///      verdict strands the slot permanently with no redelivery to hope for.
    ///
    ///      Refused until `deadline + COMMAND_EXPIRY_MARGIN` has passed on this chain (checked at execute time;
    ///      the rescue delay runs from scheduling and does not stack on the margin; rationale and sizing in
    ///      `CrosschainConstants.COMMAND_EXPIRY_MARGIN`) (IL-8591).
    ///
    ///      The command is marked CANCELLED rather than merely unlinked so its terminal state stays
    ///      readable; what stops a retry or cancel is `requireFailed` refusing on the cleared slot,
    ///      whatever the status. What stops a late receipt from being applied against a REPLACEMENT command
    ///      is the sequence comparison in `_adoptLateReceipt`, not this status (IL-7970): a receipt below the
    ///      mirror is ignored (except the epoch-only refresh for `mirror - 1`, IL-8632), and one at or above it
    ///      is adopted, retiring any replacement whose sequence the
    ///      dispatcher has already consumed.
    ///
    ///      A stored command whose dispatcher status is CANCELLED while `nextCommandSequence()` still equals
    ///      `command.sequence` is an EXPIRED no-op cancel (IL-8594): the sequence was NOT consumed, so declare
    ///      `consumed = false` for it.
    /// @param sequenceConsumed_ Whether the dispatcher resolved the command and so advanced its own
    ///        sequence (it does on BOTH a success and a cancel). The executor cannot observe this — the
    ///        receipt that would have said so is the one that was lost — so the rescue admin declares it,
    ///        from the dispatcher's public `commandStatus(commandId)` / `nextCommandSequence()`. A wrong
    ///        declaration is not terminal: should that receipt arrive after all, `acknowledge` adopts its
    ///        counters and overrides the declaration, and otherwise the timelocked `realign` sets both
    ///        mirrors to the dispatcher's observed values in either direction (IL-7970). The abandon itself
    ///        refreshes NEITHER the dispatcher's sequence nor its config epoch from any observation: it only
    ///        advances the sequence mirror on the declaration. An epoch advanced by the abandoned command (an
    ///        UPDATE_VAULTS) reaches this side only through its late receipt, which `_adoptLateReceipt`
    ///        applies to the epoch mirror alone (IL-8632); `realign` is the fallback when none arrives.
    function abandon(CcipExecutorCommandState storage self, uint256 chainId_, bool sequenceConsumed_)
        public
        returns (bytes32 commandId, uint64 sequence)
    {
        commandId = self.active[chainId_];
        if (commandId == bytes32(0)) revert NoStuckCommand(chainId_);
        // Only a command that can no longer execute may be abandoned: until its deadline has passed on the
        // dispatcher's clock too, a FAILED OffRamp message or a retry could still run it after the slot is
        // reused, and its receipt would then supersede the replacement (IL-8255). Applies to both
        // declarations, since a `sequenceConsumed = true` one may be wrong.
        uint256 abandonableAt =
            CrosschainMessages.commandDeadline(commandId) + CrosschainConstants.COMMAND_EXPIRY_MARGIN;
        if (block.timestamp <= abandonableAt) revert CommandNotExpired(commandId, abandonableAt);
        sequence = self.commands[commandId].sequence;
        self.status[commandId] = CommandStatus.CANCELLED;
        delete self.active[chainId_];
        if (sequenceConsumed_) ++self.nextCommandSequence[chainId_];
        emit CommandAbandoned(chainId_, commandId, sequence, sequenceConsumed_);
    }
}

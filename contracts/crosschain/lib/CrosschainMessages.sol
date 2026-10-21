// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {MsgType, ReturnRejectReason, CommandResolution, CrosschainConstants} from "./CrosschainConstants.sol";
import {CrosschainErrors} from "./CrosschainErrors.sol";

// =============================================================================
// Wire payload structs (ABI-encoded into the envelope `data` field).
// All amount fields are in SHARED DECIMALS (Stargate `sharedDecimals`, 6 for USDC).
// Conversion local<->shared happens only at the transport boundary (Stargate: `StargateOAppBase._toSD` / `_toLD`;
// CCIP, which uses only `Command` and the action payloads from this file: `CcipDecimalsLib`).
// See the transport READMEs (contracts/crosschain/stargate/README.md, contracts/crosschain/ccip/README.md).
// =============================================================================

/// @notice CREATE_DISPATCHER — factory-to-factory bound deployment ticket.
/// @dev Destination ticket identity is namespaced by `(srcEid, sourceFactory, requestId)`; `srcEid`
///      and `sourceFactory` come from the LayerZero `Origin`, not this payload.
///      `expiresAt` is an absolute deadline (IL-8623): the destination never deploys a ticket delivered at or
///      after it, and the source factory cancels only `DEPLOYMENT_CANCEL_MARGIN` after it, so a ticket can
///      never be both cancelled at the source and later deployed at the destination.
struct DeploymentTicket {
    uint256 requestId; // source-factory-local counter
    bytes32 salt; // CREATE3 salt = keccak256(executorCreator, userSalt)
    address executor; // == predicted dispatcher address (create3AddressOf(salt))
    uint256 srcChainId; // chain of the requesting executor
    uint256 dstChainId; // chain the dispatcher must be deployed on (require block.chainid == dstChainId)
    bytes32 assetId; // chain-independent asset identity (e.g. keccak256("USDC"))
    address admin; // rescue admin propagated to the dispatcher (raw — needed to construct it)
    address guardian; // rescue guardian propagated to the dispatcher (raw)
    uint256 rescueDelay; // rescue timelock propagated to the dispatcher (raw)
    bytes32 immutableParamsHash; // keccak(admin, guardian, rescueDelay, srcChainId, dstChainId, assetId); dest verifies
    uint256 expiresAt; // SOURCE-chain timestamp (createdAt + deploymentTtl) from which dest NACKs instead of deploying
}

/// @notice DEPLOYMENT_ACK — destination factory confirms its own recorded deployment.
struct DeploymentAck {
    uint256 requestId;
    bytes32 ticketHash; // keccak256(abi.encode(DeploymentTicket)) — complete commitment
    address dispatcher; // deployed dispatcher address (== ticket.executor)
    uint256 dstChainId;
}

/// @notice DEPLOYMENT_NACK — destination rejected the ticket (`REJECTED_OCCUPIED` or `TICKET_EXPIRED`;
///         `DESTINATION_VALIDATION` is reserved and never sent).
struct DeploymentNack {
    uint256 requestId;
    bytes32 ticketHash;
    uint8 reason; // NackReason
}

/// @notice UPDATE_VAULTS — sequenced deposit-allowlist replacement; also the born-empty initial list.
struct UpdateVaults {
    bytes32 commandId;
    uint64 sequence;
    uint64 newConfigEpoch; // must equal current commandConfigEpoch + 1 on the dispatcher
    // IL-8625: gas budget carried by the command, see `Command.minExecutionGas`
    uint64 minExecutionGas;
    address[] vaults; // bounded by MAX_ALLOWED_VAULTS; validated destination-side
}

/// @notice OUTBOUND_TRANSFER — compose payload accompanying an executor->dispatcher Stargate send.
/// @dev Carries only the transfer id; the executor binds the Stargate `guid` on send and the
///      dispatcher matches on `transferId`. Credited amount is read from the OFT compose codec.
struct OutboundTransfer {
    bytes32 transferId;
}

/// @notice TRANSFER_SETTLED — dispatcher acknowledges an inbound asset credit to the executor.
struct TransferSettled {
    bytes32 transferId;
    bytes32 guid; // Stargate guid the dispatcher observed
    uint256 amountReceivedSD; // codec-reported actual credited amount (shared decimals)
    uint64 stateVersion; // dispatcher stateVersion after crediting
}

/// @notice RETURN_ASSETS_REQUEST — recall-lane request to return assets home.
struct ReturnAssetsRequest {
    bytes32 requestId;
    uint256 amountSD; // requested amount (shared decimals)
    uint256 maxAccountedSD; // min(toSD(amount), settledRemoteBalance) — un-attested yield cannot underflow
    // manager-chosen slippage bound; the dispatcher answers RETURN_REJECTED(BELOW_MINIMUM) if the clamped send
    // or the pool's quoted credit is below it
    uint256 minReturnSD;
}

/// @notice RETURN_STARTED — authenticated return metadata sent alongside the Stargate return leg.
struct ReturnStarted {
    bytes32 requestId;
    bytes32 guid;
    uint256 amountSentSD; // actual source-debited amount (shared decimals)
    uint256 amountReceivedSD; // expected destination credit (shared decimals)
    uint64 stateVersion; // dispatcher stateVersion after decrementing tracked idle
    // dispatcher's post-debit reported balance (shared decimals): lets the executor keep an anchor for yield left
    // remote by a full recall (IL-8606). Evidence for the anchor only, never credited to `settled`.
    uint256 remoteBalanceSD;
}

/// @notice RETURN_REJECTED — dispatcher did not start a return and changed no remote accounting.
struct ReturnRejected {
    bytes32 requestId;
    ReturnRejectReason reason;
}

/// @notice COMMAND — business command wrapping a BusinessAction.
/// @dev The dispatcher stores `keccak256(abi.encode(Command))` as the immutable command commitment;
///      RETRY_COMMAND must reproduce a byte-identical commitment.
///      `minExecutionGas` (IL-8625) is the gas budget of the command: a delivery that reaches the business call with
///      less gas reverts (nothing is written, the delivery stays retryable); at or above it EVERY failure of the
///      business call, out-of-gas included, is a business failure (FAILED + NACK). The executor sets it at send time
///      from the lane's effective gas (formula in `CrosschainConstants.COMMAND_PRE_CALL_BASE`). It is part of the committed bytes, so a
///      deliverer cannot lower it and a RETRY_COMMAND re-runs the stored value. Also carried by UPDATE_VAULTS.
struct Command {
    bytes32 commandId;
    uint64 sequence; // strict: must equal dispatcher nextCommandSequence
    uint64 commandConfigEpoch; // snapshot of executor config epoch at send time
    uint8 action; // BusinessAction
    uint64 minExecutionGas; // gas budget of the business call, see above
    bytes actionData; // ABI-encoding of the per-action tuple (see decode* helpers below)
}

/// @notice RETRY_COMMAND — recall-lane retry of a FAILED command (same id + byte-identical commitment).
struct RetryCommand {
    bytes32 commandId;
    // IL-8625 (Stargate): optional raised budget, 0 = keep the stored one. The RETRY is authenticated, so it can only
    // raise: the dispatcher runs `max(stored, persisted raise, this)` and persists the maximum.
    uint64 minExecutionGas;
}

/// @notice CANCEL_COMMAND — recall-lane terminal cancel of a FAILED command.
struct CancelCommand {
    bytes32 commandId;
}

/// @notice ACK — dispatcher reports how it resolved a command + resulting state to the executor.
/// @dev The same envelope carries a success, a cancel and an expired-cancel (IL-8594) resolution. `resolution`
///      is what distinguishes them and `dispatcherConfigEpoch` is the dispatcher's authoritative post-resolution
///      epoch; the executor mirrors that value rather than deriving it from local flags.
struct CommandAck {
    bytes32 commandId;
    uint64 sequence;
    uint64 stateVersion; // dispatcher CURRENT stateVersion, evidence only: a command never bumps it (IL-8257)
    uint64 dispatcherConfigEpoch; // dispatcher commandConfigEpoch AFTER resolution (unchanged on a cancel)
    CommandResolution resolution; // SUCCEEDED, CANCELLED or EXPIRED (closed without consuming the sequence)
    int256 valueDeltaSD; // executor-side settled delta (shared decimals); always 0 (see `UnexpectedValueDelta`)
}

/// @notice NACK — dispatcher reports command failure to the executor.
struct CommandNack {
    bytes32 commandId;
    uint64 sequence;
}

/// @title CrosschainMessages
/// @notice Versioned envelope codec for all crosschain LayerZero payloads.
/// @dev Envelope = `abi.encode(uint8 codecVersion, uint8 msgType, bytes data)`. `data` is the
///      ABI-encoding of the corresponding struct above. All functions except `stampCommandId` (which reads
///      `block.timestamp`) are pure and unit-testable in isolation. Decoding rejects unsupported versions and
///      out-of-range/NONE message types.
/// @author IPOR Labs
library CrosschainMessages {
    /// @notice Thrown when the envelope codec version is not `CrosschainConstants.CODEC_VERSION`.
    error UnsupportedCodecVersion(uint8 version);
    /// @notice Thrown when the envelope message type is `NONE` or out of range.
    error UnsupportedMsgType(uint8 msgType);
    /// @notice Thrown when a decoded `action` byte is not a valid `BusinessAction`.
    error UnsupportedBusinessAction(uint8 action);

    uint8 private constant _MAX_MSG_TYPE = uint8(MsgType.RETURN_REJECTED);

    // -------------------------------------------------------------------------
    // Command id expiry (IL-8255)
    // -------------------------------------------------------------------------

    /// @notice Turn a command-id hash into a command id that carries its own expiry.
    /// @dev The high 64 bits hold `block.timestamp + COMMAND_TTL`, the low 192 bits the top of `hash_`.
    ///      Carrying the deadline in the id leaves every codec, the fuse ABIs and the stored commitments
    ///      unchanged, and it cannot be altered in transit: the id is part of the authenticated payload
    ///      and of the commitment a retry must reproduce.
    function stampCommandId(bytes32 hash_) internal view returns (bytes32) {
        return bytes32(((block.timestamp + CrosschainConstants.COMMAND_TTL) << 192) | (uint256(hash_) >> 64));
    }

    /// @notice The expiry timestamp a command id was stamped with by `stampCommandId`.
    function commandDeadline(bytes32 commandId_) internal pure returns (uint256) {
        return uint256(commandId_) >> 192;
    }

    // -------------------------------------------------------------------------
    // Command gas budget (IL-8625)
    // -------------------------------------------------------------------------

    /// @notice Number of 32-byte words of a stored payload of `len_` bytes.
    function payloadWords(uint256 len_) internal pure returns (uint256) {
        return (len_ + 31) / 32;
    }

    /// @notice The lane gas needed so that a delivery at it reaches the budget check with at least `budget_`, for a
    ///         payload of `words_` stored words. `sixtyFourth_` is true for Stargate (the real endpoint keeps `lane/64`
    ///         back on its hop to the OApp). Exact inverse of `commandGasBudget`.
    function laneGasFor(uint256 budget_, uint256 words_, bool sixtyFourth_) internal pure returns (uint256 lane) {
        uint256 need = budget_ + CrosschainConstants.COMMAND_PRE_CALL_BASE
            + CrosschainConstants.COMMAND_PRE_CALL_PER_WORD * words_;
        if (!sixtyFourth_) return need;
        lane = (need * 64 + 62) / 63;
        while (lane - lane / 64 < need) ++lane;
    }

    /// @notice The budget a command carries for a lane that delivers with `laneGas_`:
    ///         `laneGas - (Stargate: laneGas / 64) - COMMAND_PRE_CALL_BASE - COMMAND_PRE_CALL_PER_WORD * words`.
    ///         Reverts `CommandLaneGasTooLow` when the budget would be below `COMMAND_EXECUTION_MIN_GAS`. A budget above
    ///         `type(uint64).max` is capped (unreachable in practice).
    function commandGasBudget(uint256 laneGas_, uint256 words_, bool sixtyFourth_) internal pure returns (uint64) {
        uint256 minLane = laneGasFor(CrosschainConstants.COMMAND_EXECUTION_MIN_GAS, words_, sixtyFourth_);
        if (laneGas_ < minLane) revert CrosschainErrors.CommandLaneGasTooLow(laneGas_, minLane);
        uint256 budget = laneGas_ - (sixtyFourth_ ? laneGas_ / 64 : 0) - CrosschainConstants.COMMAND_PRE_CALL_BASE
            - CrosschainConstants.COMMAND_PRE_CALL_PER_WORD * words_;
        return budget > type(uint64).max ? type(uint64).max : uint64(budget);
    }

    // -------------------------------------------------------------------------
    // Envelope
    // -------------------------------------------------------------------------

    /// @notice Wrap an already-ABI-encoded payload in the versioned envelope.
    function encodeEnvelope(MsgType msgType_, bytes memory data_) internal pure returns (bytes memory) {
        return abi.encode(CrosschainConstants.CODEC_VERSION, uint8(msgType_), data_);
    }

    /// @notice Unwrap an envelope, validating the codec version and message-type range.
    /// @return msgType The decoded message type (never `NONE`).
    /// @return data The inner ABI-encoded payload bytes.
    function decodeEnvelope(bytes memory raw_) internal pure returns (MsgType msgType, bytes memory data) {
        uint8 version;
        uint8 rawType;
        (version, rawType, data) = abi.decode(raw_, (uint8, uint8, bytes));
        if (version != CrosschainConstants.CODEC_VERSION) revert UnsupportedCodecVersion(version);
        if (rawType == uint8(MsgType.NONE) || rawType > _MAX_MSG_TYPE) revert UnsupportedMsgType(rawType);
        msgType = MsgType(rawType);
    }

    // -------------------------------------------------------------------------
    // Per-type encode (returns the FULL envelope) / decode (takes the inner `data`)
    // -------------------------------------------------------------------------

    function encodeDeploymentTicket(DeploymentTicket memory t_) internal pure returns (bytes memory) {
        return encodeEnvelope(MsgType.CREATE_DISPATCHER, abi.encode(t_));
    }

    function decodeDeploymentTicket(bytes memory data_) internal pure returns (DeploymentTicket memory) {
        return abi.decode(data_, (DeploymentTicket));
    }

    function encodeDeploymentAck(DeploymentAck memory a_) internal pure returns (bytes memory) {
        return encodeEnvelope(MsgType.DEPLOYMENT_ACK, abi.encode(a_));
    }

    function decodeDeploymentAck(bytes memory data_) internal pure returns (DeploymentAck memory) {
        return abi.decode(data_, (DeploymentAck));
    }

    function encodeDeploymentNack(DeploymentNack memory n_) internal pure returns (bytes memory) {
        return encodeEnvelope(MsgType.DEPLOYMENT_NACK, abi.encode(n_));
    }

    function decodeDeploymentNack(bytes memory data_) internal pure returns (DeploymentNack memory) {
        return abi.decode(data_, (DeploymentNack));
    }

    function encodeUpdateVaults(UpdateVaults memory u_) internal pure returns (bytes memory) {
        return encodeEnvelope(MsgType.UPDATE_VAULTS, abi.encode(u_));
    }

    function decodeUpdateVaults(bytes memory data_) internal pure returns (UpdateVaults memory) {
        return abi.decode(data_, (UpdateVaults));
    }

    function encodeOutboundTransfer(OutboundTransfer memory o_) internal pure returns (bytes memory) {
        return encodeEnvelope(MsgType.OUTBOUND_TRANSFER, abi.encode(o_));
    }

    function decodeOutboundTransfer(bytes memory data_) internal pure returns (OutboundTransfer memory) {
        return abi.decode(data_, (OutboundTransfer));
    }

    function encodeTransferSettled(TransferSettled memory t_) internal pure returns (bytes memory) {
        return encodeEnvelope(MsgType.TRANSFER_SETTLED, abi.encode(t_));
    }

    function decodeTransferSettled(bytes memory data_) internal pure returns (TransferSettled memory) {
        return abi.decode(data_, (TransferSettled));
    }

    function encodeReturnAssetsRequest(ReturnAssetsRequest memory r_) internal pure returns (bytes memory) {
        return encodeEnvelope(MsgType.RETURN_ASSETS_REQUEST, abi.encode(r_));
    }

    function decodeReturnAssetsRequest(bytes memory data_) internal pure returns (ReturnAssetsRequest memory) {
        return abi.decode(data_, (ReturnAssetsRequest));
    }

    function encodeReturnStarted(ReturnStarted memory r_) internal pure returns (bytes memory) {
        return encodeEnvelope(MsgType.RETURN_STARTED, abi.encode(r_));
    }

    function decodeReturnStarted(bytes memory data_) internal pure returns (ReturnStarted memory) {
        return abi.decode(data_, (ReturnStarted));
    }

    function encodeReturnRejected(ReturnRejected memory r_) internal pure returns (bytes memory) {
        return encodeEnvelope(MsgType.RETURN_REJECTED, abi.encode(r_));
    }

    function decodeReturnRejected(bytes memory data_) internal pure returns (ReturnRejected memory) {
        return abi.decode(data_, (ReturnRejected));
    }

    function encodeCommand(Command memory c_) internal pure returns (bytes memory) {
        return encodeEnvelope(MsgType.COMMAND, abi.encode(c_));
    }

    function decodeCommand(bytes memory data_) internal pure returns (Command memory) {
        return abi.decode(data_, (Command));
    }

    function encodeRetryCommand(RetryCommand memory r_) internal pure returns (bytes memory) {
        return encodeEnvelope(MsgType.RETRY_COMMAND, abi.encode(r_));
    }

    function decodeRetryCommand(bytes memory data_) internal pure returns (RetryCommand memory) {
        return abi.decode(data_, (RetryCommand));
    }

    function encodeCancelCommand(CancelCommand memory c_) internal pure returns (bytes memory) {
        return encodeEnvelope(MsgType.CANCEL_COMMAND, abi.encode(c_));
    }

    function decodeCancelCommand(bytes memory data_) internal pure returns (CancelCommand memory) {
        return abi.decode(data_, (CancelCommand));
    }

    function encodeCommandAck(CommandAck memory a_) internal pure returns (bytes memory) {
        return encodeEnvelope(MsgType.ACK, abi.encode(a_));
    }

    function decodeCommandAck(bytes memory data_) internal pure returns (CommandAck memory) {
        return abi.decode(data_, (CommandAck));
    }

    function encodeCommandNack(CommandNack memory n_) internal pure returns (bytes memory) {
        return encodeEnvelope(MsgType.NACK, abi.encode(n_));
    }

    function decodeCommandNack(bytes memory data_) internal pure returns (CommandNack memory) {
        return abi.decode(data_, (CommandNack));
    }

    // -------------------------------------------------------------------------
    // Business action payloads (inner `Command.actionData`)
    // -------------------------------------------------------------------------

    /// @dev `amountSD_` is decoded by the dispatcher as SHARED decimals. This encoder does no conversion: the
    ///      Stargate executor forwards `Command.actionData` verbatim (callers pass shared decimals), while
    ///      CCIP callers pass LOCAL ASSET decimals and `CcipCrosschainExecutor.sendCommandToDispatcher`
    ///      normalises them via `CcipDecimalsLib.normalizeActionData`.
    function encodeDepositAction(address vault_, uint256 amountSD_, uint256 minShares_)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(vault_, amountSD_, minShares_);
    }

    function decodeDepositAction(bytes memory actionData_)
        internal
        pure
        returns (address vault, uint256 amountSD, uint256 minShares)
    {
        return abi.decode(actionData_, (address, uint256, uint256));
    }

    /// @dev `minAssets_` is SHARED decimals on the wire on BOTH transports; each dispatcher converts it with
    ///      `_toLD` before comparing it with the measured local-decimal receipt (IL-8609); `shares_` is a share
    ///      amount and never converted. No conversion here: Stargate forwards verbatim, the CCIP executor
    ///      normalises LOCAL ASSET decimals via `CcipDecimalsLib.normalizeActionData`.
    function encodeRedeemAction(address vault_, uint256 shares_, uint256 minAssets_)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(vault_, shares_, minAssets_);
    }

    function decodeRedeemAction(bytes memory actionData_)
        internal
        pure
        returns (address vault, uint256 shares, uint256 minAssets)
    {
        return abi.decode(actionData_, (address, uint256, uint256));
    }

    /// @dev `shares_` and `maxFeeShares_` are both SHARE units of `plasmaVault_` and are never converted (the CCIP
    ///      executor's `normalizeActionData` leaves REQUEST_SHARES untouched). `maxFeeShares_` is the ceiling on the
    ///      shares the dispatcher may lose across `requestShares` (the remote WithdrawManager's request fee, which it
    ///      transfers out of the dispatcher's balance); a larger measured deduction reverts the command (NACK).
    ///      `type(uint256).max` means "no ceiling"; `0` means "no fee tolerated". Wire format (IL-8603): four
    ///      words; the former three-word encoding no longer decodes.
    function encodeRequestSharesAction(
        address withdrawManager_,
        address plasmaVault_,
        uint256 shares_,
        uint256 maxFeeShares_
    ) internal pure returns (bytes memory) {
        return abi.encode(withdrawManager_, plasmaVault_, shares_, maxFeeShares_);
    }

    function decodeRequestSharesAction(bytes memory actionData_)
        internal
        pure
        returns (address withdrawManager, address plasmaVault, uint256 shares, uint256 maxFeeShares)
    {
        return abi.decode(actionData_, (address, address, uint256, uint256));
    }

    /// @dev `minAssets_` is SHARED decimals on the wire on both transports; same rule as
    ///      `encodeRedeemAction` (this encoder converts nothing).
    function encodeRedeemFromRequestAction(
        address withdrawManager_,
        address plasmaVault_,
        uint256 shares_,
        uint256 minAssets_,
        address receiver_
    ) internal pure returns (bytes memory) {
        return abi.encode(withdrawManager_, plasmaVault_, shares_, minAssets_, receiver_);
    }

    function decodeRedeemFromRequestAction(bytes memory actionData_)
        internal
        pure
        returns (address withdrawManager, address plasmaVault, uint256 shares, uint256 minAssets, address receiver)
    {
        return abi.decode(actionData_, (address, address, uint256, uint256, address));
    }
}

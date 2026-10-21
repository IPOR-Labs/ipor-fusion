// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {Origin, MessagingFee} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import {StargateOAppBase} from "./base/StargateOAppBase.sol";
import {ICrosschainDispatcher, Observation} from "../interfaces/ICrosschainDispatcher.sol";
import {IStargateDispatcherLibraryAbi} from "./IStargateDispatcherLibraryAbi.sol";
import {IPlasmaVault} from "../../interfaces/IPlasmaVault.sol";
import {CrosschainErrors} from "../lib/CrosschainErrors.sol";
import {CrosschainVaultActionLib} from "../lib/CrosschainVaultActionLib.sol";
import {TrackedVaultPricingLib} from "../lib/TrackedVaultPricingLib.sol";
import {StargateDispatcherLib} from "./lib/StargateDispatcherLib.sol";
import {PlasmaVaultStorageLib} from "../../libraries/PlasmaVaultStorageLib.sol";
import {
    MsgType,
    BusinessAction,
    CommandStatus,
    CommandResolution,
    ReturnRejectReason,
    CrosschainConstants
} from "../lib/CrosschainConstants.sol";
import {
    CrosschainMessages,
    Command,
    CommandAck,
    CommandNack,
    OutboundTransfer,
    TransferSettled,
    ReturnStarted,
    ReturnRejected,
    ReturnAssetsRequest,
    UpdateVaults,
    RetryCommand,
    CancelCommand
} from "../lib/CrosschainMessages.sol";

/// @notice Minimal view of the request info returned by `WithdrawManager.requestInfo`. Mirrors
///         `contracts/managers/withdraw/WithdrawManager.sol#WithdrawRequestInfo` field-for-field so the
///         ABI decode is layout-compatible without importing the heavy upgradeable contract.
struct WithdrawRequestInfoView {
    uint256 shares;
    uint256 endWithdrawWindowTimestamp;
    bool canWithdraw;
    uint256 withdrawWindowInSeconds;
}

/// @notice Minimal async-redemption surface the dispatcher drives on the remote WithdrawManager.
interface IWithdrawManagerLike {
    function requestShares(uint256 shares_) external;
    function requestInfo(address account_) external view returns (WithdrawRequestInfoView memory);
}

/// @title StargateCrosschainDispatcher
/// @notice Remote-chain half of the crosschain POC (spec §10). Deployed by the remote factory
///         via CREATE3 at the SAME address as its executor; has NO manager — only authenticated
///         crosschain messages from its single executor act, besides the timelocked rescue-admin exits
///         (generic rescue, admin recall, force-untrack). Executes deposit/redeem/request/redeem-from
///         -request against whitelisted PlasmaVaults, tracks remote idle + live positions, and answers
///         business commands over a strictly-sequenced lane plus a recall lane that occupies no sequence
///         of its own (its retry/cancel still resolve the record holding the current one).
/// @dev Concrete `StargateOAppBase`: implements the inbound message/compose hooks. Business actions run
///      via a self-call so their reverts convert to a persisted FAILED status + NACK (never a lost
///      message). Tracked idle is stored in SHARED decimals; conversion to local ASSET decimals happens
///      only at the API surface. Direct donations / pre-compose tokens are NEVER added to `trackedIdle`.
/// @author IPOR Labs
contract StargateCrosschainDispatcher is StargateOAppBase, ICrosschainDispatcher, IStargateDispatcherLibraryAbi {
    /// @notice Enforced-options key for plain LayerZero sends (receipts/return metadata).
    uint16 internal constant MSG_OPTION_TYPE = 1;

    // ============================================================
    // Immutables (§10)
    // ============================================================

    /// @notice The factory that deployed this dispatcher (CREATE3).
    address public immutable FACTORY;

    /// @notice Chain-independent asset identity (e.g. `keccak256("USDC")`).
    bytes32 public immutable ASSET_ID;

    /// @notice The single executor chain authorized to command this dispatcher (fixed at construction).
    uint256 public immutable override EXECUTOR_CHAIN_ID;

    /// @notice The endpoint id of `EXECUTOR_CHAIN_ID` (its return/ack path).
    uint32 public immutable EXECUTOR_EID;

    // ============================================================
    // Vault sets (§10)
    // ============================================================

    /// @notice The deposit allowlist (gates new value entry); replaced by UPDATE_VAULTS.
    address[] public allowedDepositVaults;

    /// @notice Whether a vault is currently on the deposit allowlist.
    mapping(address vault => bool allowed) public isAllowedVault;

    /// @notice The tracked-position set (vaults with live shares). A vault that leaves the allowlist via
    ///         `UPDATE_VAULTS` is swept (best effort) and ALWAYS untracked (IL-8784); a residual is outside NAV
    ///         until the vault is allowlisted again.
    address[] public trackedPositionVaults;

    /// @notice Whether a vault is in the tracked-position set.
    mapping(address vault => bool tracked) public isTrackedVault;

    // ============================================================
    // Accounting & sequencing (§10)
    // ============================================================

    /// @notice Tracked remote idle ASSET (shared decimals). Only authenticated compose credits, measured
    ///         business-action and recall-send deltas, and the timelocked admin recall (IL-8251) mutate this —
    ///         NEVER `balanceOf`.
    uint256 public trackedIdle;

    /// @notice Next expected business-command sequence (strict `sequence == nextCommandSequence`).
    uint64 public nextCommandSequence;

    /// @notice Current deposit-allowlist config epoch.
    uint64 public commandConfigEpoch;

    /// @notice Monotonic state version (version frontier, §10). Invariant (IL-8257): it equals the number of
    ///         VALUE-MOVING transitions — an inbound transfer settle and a return-started — and nothing else.
    ///         Value-neutral traffic (command success, command cancel, vault-config update, and so the
    ///         `COMMAND_ACK` that reports them) carries the CURRENT version as evidence without bumping it.
    ///         The executor's version frontier counts the same transitions, so it never drifts on command
    ///         traffic.
    uint64 public override stateVersion;

    /// @notice Lifecycle status per command id.
    mapping(bytes32 commandId => CommandStatus status) public commandStatus;

    /// @notice A persisted command for retry re-execution (byte-identical work).
    /// @param msgType The envelope message type (COMMAND or UPDATE_VAULTS).
    /// @param sequence The sequence the command occupies.
    /// @param commitment `keccak256(abi.encode(uint8(msgType), data))` — the permanent binding of this
    ///        command id to one byte-identical operation. Any redelivery must reproduce it (§9 P2).
    /// @param data The inner ABI-encoded payload (re-run verbatim on retry).
    struct StoredCommand {
        uint8 msgType;
        uint64 sequence;
        bytes32 commitment;
        bytes data;
        // IL-8625: the highest budget a RETRY_COMMAND raised for this command (0 = none); the effective budget of
        // every later run is `max(command.minExecutionGas, raisedBudget)`. Appended last.
        uint64 raisedBudget;
    }

    /// @notice Persisted commands by command id (for authenticated retry).
    mapping(bytes32 commandId => StoredCommand command) internal _storedCommands;

    /// @notice Recall-lane consumed status per return request id (idempotent no-op on replay).
    mapping(bytes32 requestId => bool consumed) public recallConsumed;

    /// @notice Whether an inbound outbound-transfer id has already been settled (idempotency).
    mapping(bytes32 transferId => bool settled) public transferSettled;

    // ============================================================
    // Events
    // ============================================================

    event VaultsUpdated(uint64 commandConfigEpoch, uint64 stateVersion, uint256 count);
    event DepositExecuted(address vault, uint256 assetSpentSD, uint256 sharesDelta);
    event RedeemExecuted(address vault, uint256 sharesRedeemed, uint256 assetsDeltaSD);
    /// @dev `feeShares` is the MEASURED drop of this contract's vault-share balance across `requestShares`.
    event SharesRequested(address vault, uint256 pendingShares, uint256 feeShares);
    event RedeemedFromRequest(address vault, uint256 sharesRedeemed, uint256 assetsDeltaSD);
    event CommandSucceeded(bytes32 commandId, uint64 sequence, uint64 stateVersion, int256 valueDeltaSD);
    event CommandFailed(bytes32 commandId, uint64 sequence);
    event CommandCancelled(bytes32 commandId, uint64 sequence);
    /// @notice A CANCEL_COMMAND for a FAILED command still owning the lane's next sequence arrived past the
    ///         command's deadline (IL-8594). Closed as CANCELLED, sequence NOT consumed, answered with an `EXPIRED`
    ///         receipt. Pairs with the executor's `CommandExpiryReleased`.
    event CancelCommandExpiredIgnored(bytes32 commandId, uint64 sequence);
    /// @notice A RETRY_COMMAND / CANCEL_COMMAND named a FAILED record whose sequence the lane has already
    ///         passed. Consumed as a no-op: no state change, no receipt. Pairs with the executor's
    ///         `CommandAbandoned(chainId, commandId, sequence, sequenceConsumed = false)` for the same
    ///         command id (IL-7979).
    event StaleCommandResolutionIgnored(bytes32 commandId, uint64 sequence, uint64 nextCommandSequence);
    event InboundTransferSettled(bytes32 transferId, uint256 amountSD, uint64 stateVersion);
    event ReturnAssetsSent(bytes32 requestId, bytes32 guid, uint256 amountSentSD, uint256 amountReceivedSD);
    event ReturnAssetsRejected(bytes32 requestId, uint8 reason);
    /// @notice A tracked vault was removed from the tracked set by the timelocked admin write-off (IL-8602),
    ///         whatever its share balance. `sharesLeft` is the balance read at that moment (0 if unreadable); the
    ///         shares stay in this contract and drop out of every observation.
    event TrackedVaultWrittenOff(address vault, uint256 sharesLeft);

    // ============================================================
    // Constructor
    // ============================================================

    /// @param endpoint_ LayerZero V2 endpoint (destination-local).
    /// @param asset_ Destination-local ERC20 asset (resolved by the remote factory).
    /// @param stargatePool_ Destination-local Stargate pool for `asset_`.
    /// @param assetId_ Chain-independent asset identity.
    /// @param factory_ The deploying factory, passed explicitly (see the constructor body).
    /// @param admin_ Rescue admin (propagated from the executor).
    /// @param guardian_ Rescue guardian (propagated; distinct from admin).
    /// @param rescueDelay_ Rescue timelock (propagated).
    /// @param executorChainId_ The single executor chain id.
    /// @param executorEid_ The endpoint id of `executorChainId_`.
    /// @param enforcedOptions_ ABI-encoded `EnforcedOptionParam[]` for the executor path (or empty).
    constructor(
        address endpoint_,
        address asset_,
        address stargatePool_,
        bytes32 assetId_,
        address factory_,
        address admin_,
        address guardian_,
        uint256 rescueDelay_,
        uint256 executorChainId_,
        uint32 executorEid_,
        bytes memory enforcedOptions_
    ) StargateOAppBase(endpoint_, admin_, admin_, guardian_, rescueDelay_, asset_, stargatePool_) {
        // The factory is injected EXPLICITLY (not `msg.sender`): Solady CREATE3 deploys through an
        // ephemeral proxy, so `msg.sender` here is that proxy. `factory_` does not affect the CREATE3
        // address (salt + deployer only), so the dispatcher still lands at the executor's address.
        if (factory_ == address(0)) revert CrosschainErrors.ZeroAddress();
        FACTORY = factory_;
        ASSET_ID = assetId_;
        EXECUTOR_CHAIN_ID = executorChainId_;
        EXECUTOR_EID = executorEid_;

        // Register the single fixed counterparty path (its same-address peer + return/ack enforced
        // options). Born with an EMPTY allowlist — the initial list arrives as the first sequenced
        // UPDATE_VAULTS command, so the constructor never depends on destination state.
        _registerPath(executorChainId_, executorEid_, enforcedOptions_);

        // Seal ownership last (spec §8).
        _transferOwnership(address(0));
    }

    // ============================================================
    // Views (ICrosschainDispatcher)
    // ============================================================

    /// @inheritdoc ICrosschainDispatcher
    function observation() external view override returns (Observation memory) {
        uint256 len = trackedPositionVaults.length;
        address[] memory vaults = new address[](len);
        uint256[] memory values = new uint256[](len);
        bool[] memory valued = new bool[](len);
        uint256 unpriced;
        for (uint256 i; i < len; ++i) {
            address v = trackedPositionVaults[i];
            vaults[i] = v;
            // A faulty tracked vault is flagged instead of reverting the whole view (IL-8602).
            // View budget for `convertToAssets` (eth_call only; IL-8602 review G-1).
            (uint256 assets, uint8 reason) = TrackedVaultPricingLib.price(
                v,
                address(this),
                _assetImm(),
                TrackedVaultPricingLib.VIEW_CONVERT_GAS
            );
            if (reason == TrackedVaultPricingLib.PRICED) {
                values[i] = assets;
                valued[i] = true;
            } else {
                ++unpriced;
            }
        }
        return
            Observation({
                trackedIdle: _toLD(trackedIdle),
                trackedVaults: vaults,
                vaultAssetValues: values,
                stateVersion: stateVersion,
                commandConfigEpoch: commandConfigEpoch,
                trackedPositionSetHash: _trackedPositionSetHash(),
                vaultValued: valued,
                unpricedCount: unpriced
            });
    }

    /// @notice The current deposit allowlist.
    function getAllowedVaults() external view returns (address[] memory) {
        return allowedDepositVaults;
    }

    /// @notice The current tracked-position set (a vault allowlisted again is tracked again).
    function getTrackedVaults() external view returns (address[] memory) {
        return trackedPositionVaults;
    }

    /// @notice Reader executed by a remote PlasmaVault's `UniversalReader.read` in THAT vault's storage
    ///         context. Returns the manager the vault's own `redeemFromRequest` consults. Executed directly on
    ///         this contract it reports this contract's own slots, which nothing here writes.
    /// @dev IL-8608: deliberately reads WITH the legacy fallback (`getWithdrawManagerAddressWithLegacyFallback`),
    ///      unlike the "new code reads the corrected slot only" rule. A remote PlasmaVault deployed from a
    ///      pre-IL-6952 base keeps its manager in `WITHDRAW_MANAGER_LEGACY_SLOT`; a corrected-slot-only read
    ///      returns `address(0)` there, so the manager check could never match the real manager. The vault's
    ///      own code is the thing being mirrored, and remote vaults may run either layout.
    function plasmaVaultWithdrawManager() external view returns (address) {
        return PlasmaVaultStorageLib.getWithdrawManagerAddressWithLegacyFallback();
    }

    // ============================================================
    // Inbound message routing (§10)
    // ============================================================

    /// @notice Handle a decoded, authenticated inbound plain message (peer already verified by the base).
    /// @dev Routes sequenced commands and the recall lane; binds the source to the single executor (§10).
    function _handleLzMessage(
        MsgType msgType_,
        uint256 srcChainId_,
        Origin calldata,
        bytes memory data_
    ) internal override {
        // Base already verified endpoint + same-address peer + EID mapping; additionally bind the source
        // chain to the single authorized executor.
        if (srcChainId_ != _executorChainIdImm()) {
            revert CrosschainErrors.WrongSourceChain(_executorChainIdImm(), srcChainId_);
        }
        if (msgType_ == MsgType.COMMAND) {
            Command memory c = CrosschainMessages.decodeCommand(data_);
            _runSequenced(c.commandId, c.sequence, uint8(MsgType.COMMAND), data_);
        } else if (msgType_ == MsgType.UPDATE_VAULTS) {
            UpdateVaults memory u = CrosschainMessages.decodeUpdateVaults(data_);
            _runSequenced(u.commandId, u.sequence, uint8(MsgType.UPDATE_VAULTS), data_);
        } else if (msgType_ == MsgType.RETURN_ASSETS_REQUEST) {
            _onReturnAssetsRequest(CrosschainMessages.decodeReturnAssetsRequest(data_));
        } else if (msgType_ == MsgType.RETRY_COMMAND) {
            RetryCommand memory r = CrosschainMessages.decodeRetryCommand(data_);
            _onRetryCommand(r.commandId, r.minExecutionGas);
        } else if (msgType_ == MsgType.CANCEL_COMMAND) {
            _onCancelCommand(CrosschainMessages.decodeCancelCommand(data_).commandId);
        } else {
            revert CrosschainErrors.UnexpectedMessageType(uint8(msgType_));
        }
    }

    /// @inheritdoc StargateOAppBase
    function _handleCompose(
        uint256 srcChainId_,
        bytes32 guid_,
        uint256 amountLD_,
        MsgType msgType_,
        bytes memory data_
    ) internal override {
        if (srcChainId_ != _executorChainIdImm()) {
            revert CrosschainErrors.WrongSourceChain(_executorChainIdImm(), srcChainId_);
        }
        if (msgType_ != MsgType.OUTBOUND_TRANSFER) revert CrosschainErrors.UnexpectedMessageType(uint8(msgType_));

        bytes32 transferId = CrosschainMessages.decodeOutboundTransfer(data_).transferId;
        if (transferSettled[transferId]) return; // idempotent

        // Only the codec-reported, four-fold-authenticated compose amount enters tracked idle.
        uint256 amountSD = _toSD(amountLD_);
        trackedIdle += amountSD;
        transferSettled[transferId] = true;
        unchecked {
            ++stateVersion;
        }
        // Send the settlement receipt LAST: if the native budget cannot fund it, `_sendLzMessage`
        // reverts and the WHOLE compose reverts atomically (tokens remain credited, retryable) — the
        // accounting never partially settles.
        bytes memory payload = CrosschainMessages.encodeTransferSettled(
            TransferSettled({
                transferId: transferId,
                guid: guid_,
                amountReceivedSD: amountSD,
                stateVersion: stateVersion
            })
        );
        _sendLzMessage(_executorChainIdImm(), payload, MSG_OPTION_TYPE, "");
        emit InboundTransferSettled(transferId, amountSD, stateVersion);
    }

    // ============================================================
    // Sequenced lane (COMMAND / UPDATE_VAULTS)
    // ============================================================

    function _runSequenced(bytes32 commandId_, uint64 sequence_, uint8 msgType_, bytes memory data_) private {
        bytes32 commitment = keccak256(abi.encode(msgType_, data_));
        CommandStatus st = commandStatus[commandId_];

        if (st != CommandStatus.NONE) {
            // A command id already exists: any redelivery MUST be byte-identical to the originally stored
            // work — same message type, sequence and payload commitment. A mismatch reverts and never
            // overwrites stored data, so a failed command cannot be silently replaced (§9 P2 item 4).
            StoredCommand storage sc = _storedCommands[commandId_];
            if (sc.msgType != msgType_ || sc.sequence != sequence_ || sc.commitment != commitment) {
                revert CrosschainErrors.CommandCommitmentMismatch(commandId_);
            }
            // A resolved command is idempotent: the original ACK/NACK packet (not command redelivery) is
            // what LayerZero retries. Only a FAILED command is re-executed here (same-sequence
            // re-delivery). This branch cannot be reached with a sequence the lane has already passed, for
            // two independent reasons. First, a stored FAILED record exists only if the delivery that wrote
            // it committed, and a committed delivery is one the endpoint cleared, so that packet can never
            // be re-executed; a delivery that reverted instead (a below-budget `InsufficientGasForCommand` and
            // `_recordFailure`'s `InsufficientGasForNack` included) stored nothing at all, so its retained packet
            // takes the fresh-command branch below and meets `SequenceGap`. Second, the executor never re-sends
            // a COMMAND / UPDATE_VAULTS envelope at all — every build mints a fresh id from `++_commandNonce`.
            // Hence no stale-sequence guard here — unlike a RETRY_COMMAND / CANCEL_COMMAND already in
            // flight, which names a FAILED record explicitly and stays executable after an abandon has
            // freed the slot; see `_onRetryCommand` / `_onCancelCommand` for the guarded sites.
            // A sequence the lane has NOT reached yet is a different matter: a fresh packet retained on
            // `SequenceGap`, or one retained at the lane's current sequence by a failed budget quote, stays
            // executable after its command was abandoned on the executor and would run once the lane
            // reaches it. The command TTL, checked first in `_executeStoredCommand` (IL-8625) and again in
            // `runBusinessSelf`, is what keeps that from executing the abandoned intent (IL-8255).
            if (st == CommandStatus.SUCCEEDED || st == CommandStatus.CANCELLED) return;
            // st == FAILED: re-run the byte-identical stored work below (do NOT overwrite the record).
            _ensureReceiptBudget();
        } else {
            // Strict sequencing for fresh work: a gap reverts so LZ retains the packet for retry after
            // predecessors (§10). Quote the receipt fee BEFORE the business action so "cannot pay for
            // receipt" is a clean pre-revert and never conflates with a business NACK (§10).
            if (sequence_ != nextCommandSequence) revert CrosschainErrors.SequenceGap(nextCommandSequence, sequence_);
            _ensureReceiptBudget();
            _storedCommands[commandId_] = StoredCommand({
                msgType: msgType_,
                sequence: sequence_,
                commitment: commitment,
                data: data_,
                raisedBudget: 0
            });
        }
        commandStatus[commandId_] = CommandStatus.PENDING;
        _executeStoredCommand(commandId_, sequence_, msgType_, data_);
    }

    function _executeStoredCommand(bytes32 commandId_, uint64 sequence_, uint8 msgType_, bytes memory data_) private {
        // IL-8625: the first delivery is permissionless with no gas stipend. A delivery that reaches this point with
        // less gas than the command's budget (`minExecutionGas`, stored in the committed bytes, so a deliverer cannot
        // lower it; a retry re-runs it, raised by any authenticated RETRY raise) reverts, state included, and the packet stays retryable. At or above the
        // budget every failure of the business call is a business failure: the catch below records FAILED and sends
        // the NACK without classifying the revert data. The self-call keeps `COMMAND_CATCH_RESERVE_GAS` for the
        // catch frame. The budget is at least the floor, which exceeds the reserve, so the subtraction cannot
        // underflow.
        //
        // The command deadline is checked FIRST (IL-8625): an expired command can never run, so it skips the budget
        // check and the business call and goes straight to the failure path (FAILED + NACK; the manager's CANCEL,
        // which pays its fee and honours the IL-8579 cooldown, then gets the IL-8594 `EXPIRED` receipt), with enough gas to
        // store the payload and send the NACK (on the real endpoint that costs more than `MIN_NACK_GAS`). Otherwise a
        // command whose budget can never be delivered (a top-up above what the destination chain accepts in one
        // transaction) would revert forever, never NACK and only the admin's ABANDON could free the lane. The
        // deadline stays inclusive (`>`), as in `runBusinessSelf`.
        if (block.timestamp > CrosschainMessages.commandDeadline(commandId_)) {
            _recordFailure(commandId_, sequence_);
            return;
        }
        uint256 required = _commandBudget(commandId_, msgType_, data_);
        if (gasleft() < required) revert CrosschainErrors.InsufficientGasForCommand(gasleft(), required);
        try
            this.runBusinessSelf{gas: gasleft() - CrosschainConstants.COMMAND_CATCH_RESERVE_GAS}(
                commandId_,
                msgType_,
                data_
            )
        returns (int256 deltaSD) {
            commandStatus[commandId_] = CommandStatus.SUCCEEDED;
            unchecked {
                ++nextCommandSequence;
            }
            _sendCommandAck(commandId_, sequence_, deltaSD, CommandResolution.SUCCEEDED);
            emit CommandSucceeded(commandId_, sequence_, stateVersion, deltaSD);
        } catch {
            // IL-8625: the delivery had at least the command's budget, so whatever the business call did (a decodable
            // error, an empty revert, out-of-gas, `InsufficientGasForVaultRead`) is a business failure. Only the
            // gas for the NACK itself is guarded.
            _recordFailure(commandId_, sequence_);
        }
    }

    /// @dev FAILED + NACK, shared by the caught business failure and the expired-command short cut. Only the gas for
    ///      the NACK itself is guarded (`MIN_NACK_GAS`).
    function _recordFailure(bytes32 commandId_, uint64 sequence_) private {
        if (gasleft() < CrosschainConstants.MIN_NACK_GAS) {
            revert CrosschainErrors.InsufficientGasForNack(gasleft(), CrosschainConstants.MIN_NACK_GAS);
        }
        // FAILED: sequence NOT advanced; the packet's work persists as FAILED until authenticated
        // retry/cancel on the recall lane resolves it at its own sequence. A record the lane has since
        // passed is dead instead: any retry/cancel packet still naming it is ignored (IL-7979).
        commandStatus[commandId_] = CommandStatus.FAILED;
        _sendCommandNack(commandId_, sequence_);
        emit CommandFailed(commandId_, sequence_);
    }

    /// @dev The gas budget of a stored COMMAND / UPDATE_VAULTS: the committed `minExecutionGas`, raised by any RETRY
    ///      raise (`raisedBudget`), never below `COMMAND_EXECUTION_MIN_GAS`.
    function _commandBudget(
        bytes32 commandId_,
        uint8 msgType_,
        bytes memory data_
    ) private view returns (uint256 budget) {
        budget = msgType_ == uint8(MsgType.COMMAND)
            ? CrosschainMessages.decodeCommand(data_).minExecutionGas
            : CrosschainMessages.decodeUpdateVaults(data_).minExecutionGas;
        uint256 raised = _storedCommands[commandId_].raisedBudget;
        if (raised > budget) budget = raised;
        if (budget < CrosschainConstants.COMMAND_EXECUTION_MIN_GAS)
            budget = CrosschainConstants.COMMAND_EXECUTION_MIN_GAS;
    }

    /// @notice Self-only business-action runner (external so the sequenced lane can try/catch reverts).
    /// @dev MUST be called only by `address(this)`; not part of the external API surface for others.
    /// @param commandId_ The command's id, as decoded from `data_` by the sequenced lane.
    /// @param msgType_ The envelope message type (COMMAND or UPDATE_VAULTS).
    /// @param data_ The inner ABI-encoded payload.
    /// @return deltaSD The executor-side settled delta (0 for POC business actions — value stays remote).
    function runBusinessSelf(
        bytes32 commandId_,
        uint8 msgType_,
        bytes calldata data_
    ) external returns (int256 deltaSD) {
        if (msg.sender != address(this)) revert CrosschainErrors.OnlySelf(msg.sender);
        // Expired work is NACKed, never run: a packet retained across an executor-side abandon would
        // otherwise execute the abandoned intent (IL-8255). `_executeStoredCommand` already sends an expired
        // fresh delivery, FAILED redelivery or retry to FAILED + NACK before the budget check (IL-8625), so
        // this check is a backstop; either way the sequence does not move.
        if (block.timestamp > CrosschainMessages.commandDeadline(commandId_)) {
            revert CrosschainErrors.CommandExpired(commandId_);
        }
        if (msgType_ == uint8(MsgType.COMMAND)) {
            Command memory c = CrosschainMessages.decodeCommand(data_);
            // A business command must be built against the CURRENT deposit-allowlist config epoch. A stale
            // or future epoch means the command targets a different allowlist generation; reject it (this
            // reverts inside the self-call, so it becomes a NACK the recall lane can retry/cancel) (§9 P2
            // item 5). UPDATE_VAULTS keeps its own `commandConfigEpoch + 1` rule in `StargateDispatcherLib.applyUpdateVaults`.
            if (c.commandConfigEpoch != commandConfigEpoch) {
                revert CrosschainErrors.ConfigEpochMismatch(commandConfigEpoch, c.commandConfigEpoch);
            }
            return _runBusinessAction(c.action, c.actionData);
        } else if (msgType_ == uint8(MsgType.UPDATE_VAULTS)) {
            // The next epoch is stored first: `applyUpdateVaults` reverts this whole self-call unless the payload
            // carries exactly `epoch + 1`, which rolls the write back. Vaults that left the allowlist are swept into
            // idle and untracked in the same linked call (IL-8784); the redeemed assets become idle, so the
            // executor's settled bucket is unchanged (value-neutral, delta stays 0).
            uint64 epoch = commandConfigEpoch;
            commandConfigEpoch = epoch + 1;
            trackedIdle += _toSD(
                StargateDispatcherLib.applyUpdateVaults(
                    allowedDepositVaults,
                    isAllowedVault,
                    isTrackedVault,
                    trackedPositionVaults,
                    epoch,
                    stateVersion,
                    _assetImm(),
                    data_
                )
            );
            return 0;
        }
        revert CrosschainErrors.UnexpectedMessageType(msgType_);
    }

    function _runBusinessAction(uint8 action_, bytes memory actionData_) private returns (int256) {
        if (action_ == uint8(BusinessAction.DEPOSIT)) {
            (address vault, uint256 amountSD, uint256 minShares) = CrosschainMessages.decodeDepositAction(actionData_);
            _deposit(vault, amountSD, minShares);
        } else if (action_ == uint8(BusinessAction.REDEEM)) {
            (address vault, uint256 shares, uint256 minAssets) = CrosschainMessages.decodeRedeemAction(actionData_);
            _redeem(vault, shares, minAssets);
        } else if (action_ == uint8(BusinessAction.REQUEST_SHARES)) {
            (address wm, address plasmaVault, uint256 shares, uint256 maxFeeShares) = CrosschainMessages
                .decodeRequestSharesAction(actionData_);
            _requestShares(wm, plasmaVault, shares, maxFeeShares);
        } else if (action_ == uint8(BusinessAction.REDEEM_FROM_REQUEST)) {
            (address wm, address plasmaVault, uint256 shares, uint256 minAssets, address receiver) = CrosschainMessages
                .decodeRedeemFromRequestAction(actionData_);
            _redeemFromRequest(wm, plasmaVault, shares, minAssets, receiver);
        } else {
            revert CrosschainErrors.UnexpectedMessageType(action_);
        }
        // Business actions rearrange remote value (idle <-> position) without moving it cross-chain, so
        // the executor's settled bucket is unchanged; attestation re-marks yield periodically (§9/§10).
        return 0;
    }

    // ============================================================
    // Business actions (measured deltas)
    // ============================================================

    function _deposit(address vault_, uint256 amountSD_, uint256 minShares_) private {
        if (!isAllowedVault[vault_]) revert CrosschainErrors.VaultNotAllowed(vault_);
        _assertVaultAsset(vault_);
        uint256 amountLD = _min(_toLD(amountSD_), _toLD(trackedIdle));
        if (amountLD == 0) revert CrosschainErrors.ZeroAmount();

        uint256 assetBefore = IERC20(_assetImm()).balanceOf(address(this));

        uint256 sharesDelta = CrosschainVaultActionLib.depositScoped(_assetImm(), vault_, amountLD);

        uint256 assetSpent = assetBefore - IERC20(_assetImm()).balanceOf(address(this));
        if (sharesDelta < minShares_) revert CrosschainErrors.InsufficientShares(sharesDelta, minShares_);

        // Debit the tracked ledger conservatively: round the measured spend UP (as the CCIP dispatcher does) so
        // truncation can never leave `trackedIdle` claiming value the dispatcher no longer holds. Cannot exceed
        // `trackedIdle`: `assetSpent <= amountLD <= _toLD(trackedIdle)` and `amountLD` is a whole SD multiple.
        uint256 spentSD = _toSD(assetSpent + _toLD(1) - 1);
        trackedIdle -= spentSD;
        _addTrackedVault(vault_);
        emit DepositExecuted(vault_, spentSD, sharesDelta);
    }

    /// @dev IL-8645: admission checked `asset()` once; an upgradeable vault can change it later. Re-assert before any
    ///      approval. Redeems are deliberately not gated so a drifted position can always be exited.
    function _assertVaultAsset(address vault_) private view {
        address actual = IERC4626(vault_).asset();
        if (actual != _assetImm()) revert CrosschainErrors.VaultAssetDrifted(vault_, actual);
    }

    function _redeem(address vault_, uint256 shares_, uint256 minAssets_) private {
        if (!isTrackedVault[vault_]) revert CrosschainErrors.VaultNotTracked(vault_);
        uint256 redeemShares = _min(shares_, IERC20(vault_).balanceOf(address(this)));
        if (redeemShares == 0) revert CrosschainErrors.ZeroAmount();

        uint256 assetBefore = IERC20(_assetImm()).balanceOf(address(this));
        IERC4626(vault_).redeem(redeemShares, address(this), address(this));
        emit RedeemExecuted(vault_, redeemShares, _creditRedeemed(vault_, assetBefore, minAssets_));
    }

    /// @dev Credits the measured asset delta to the tracked idle ledger and untracks the vault if it is now empty.
    function _creditRedeemed(
        address vault_,
        uint256 assetBefore_,
        uint256 minAssets_
    ) private returns (uint256 deltaSD) {
        uint256 assetsDelta = IERC20(_assetImm()).balanceOf(address(this)) - assetBefore_;
        uint256 minAssetsLD = _toLD(minAssets_); // IL-8609: wire floor is SD, receipts are LD
        if (assetsDelta < minAssetsLD) revert CrosschainErrors.InsufficientAssets(assetsDelta, minAssetsLD);
        deltaSD = _toSD(assetsDelta);
        trackedIdle += deltaSD;
        _maybeUntrack(vault_);
    }

    function _requestShares(
        address withdrawManager_,
        address plasmaVault_,
        uint256 shares_,
        uint256 maxFeeShares_
    ) private {
        if (!isTrackedVault[plasmaVault_]) revert CrosschainErrors.VaultNotTracked(plasmaVault_);
        _requireVaultWithdrawManager(plasmaVault_, withdrawManager_);
        // Cannot request to withdraw more shares than the dispatcher actually holds (§8 P3 item 3). The
        // WithdrawManager fee comes out of the request (recorded = shares - fee) and is moved from this balance, so
        // the recorded post-fee request is still bounded correctly.
        uint256 shareBalance = IERC20(plasmaVault_).balanceOf(address(this));
        if (shares_ > shareBalance) revert CrosschainErrors.RequestSharesUnavailable(shareBalance, shares_);

        IWithdrawManagerLike(withdrawManager_).requestShares(shares_);
        // Bound the fee the (remotely mutable) manager took out of this contract's shares (IL-8603).
        uint256 balanceAfter = IERC20(plasmaVault_).balanceOf(address(this));
        uint256 deducted = shareBalance > balanceAfter ? shareBalance - balanceAfter : 0;
        if (maxFeeShares_ != type(uint256).max && deducted > maxFeeShares_) {
            revert CrosschainErrors.RequestSharesFeeExceeded(plasmaVault_, deducted, shares_, maxFeeShares_);
        }
        uint256 afterShares = IWithdrawManagerLike(withdrawManager_).requestInfo(address(this)).shares;

        // The WithdrawManager REPLACES its stored request on every `requestShares` and takes the fee out of this
        // contract's shares, so the event reports the manager's read-back outstanding request. The dispatcher
        // keeps no copy (IL-8410): the manager bounds REDEEM_FROM_REQUEST and `balanceOf` alone proves a live
        // position.
        emit SharesRequested(plasmaVault_, afterShares, deducted);
    }

    function _redeemFromRequest(
        address withdrawManager_,
        address plasmaVault_,
        uint256 shares_,
        uint256 minAssets_,
        address receiver_
    ) private {
        if (receiver_ != address(this)) revert CrosschainErrors.ReceiverMustBeSelf(receiver_);
        if (!isTrackedVault[plasmaVault_]) revert CrosschainErrors.VaultNotTracked(plasmaVault_);
        // Consistency check only — the vault executes the redeem against its own manager; see
        // `_requireVaultWithdrawManager`.
        _requireVaultWithdrawManager(plasmaVault_, withdrawManager_);
        // The request bound is enforced by the vault's WithdrawManager (`canWithdrawFromRequest`).
        uint256 assetBefore = IERC20(_assetImm()).balanceOf(address(this));
        IPlasmaVault(plasmaVault_).redeemFromRequest(shares_, address(this), address(this));
        emit RedeemedFromRequest(plasmaVault_, shares_, _creditRedeemed(plasmaVault_, assetBefore, minAssets_));
    }

    // ============================================================
    // Recall lane: RETURN_ASSETS_REQUEST / RETRY / CANCEL. Exempt from occupying a NEW sequence, but
    // RETRY and CANCEL resolve a record and so must still name the one that owns the lane's next
    // sequence (IL-7979); only RETURN_ASSETS_REQUEST is sequence-free.
    // ============================================================

    function _onReturnAssetsRequest(ReturnAssetsRequest memory r_) private {
        if (recallConsumed[r_.requestId]) return; // idempotent no-op / re-ACK

        // Send no more than the bound and the tracked idle — idempotency-safe by construction (§10).
        uint256 sendLD = _min(_min(_toLD(r_.amountSD), _toLD(r_.maxAccountedSD)), _toLD(trackedIdle));
        if (sendLD == 0) {
            _rejectReturn(r_.requestId, ReturnRejectReason.NO_TRACKED_IDLE);
            return;
        }
        // The manager's floor is ABSOLUTE and is forwarded to the pool un-scaled (below). On the honest
        // path a floor above the accounted bound is already refused at request time by the executor's
        // `StargateExecutorAccountingLib.buildReturnRequest`, so remote idle short of the request is the
        // expected cause here — but that guard lives on the source chain and is NOT re-checked on this
        // side: `amountSD`, `maxAccountedSD` and `minReturnSD` arrive over the wire and are not validated
        // by `decodeReturnAssetsRequest`, so this branch must hold for any triple it is handed — any of the
        // three terms of the `min` above can be the binding one (see
        // `DispatcherTest.testShouldRejectRecallBelowFloorWithBelowMinimumReason`, which reaches it through
        // `maxAccountedSD` with idle to spare). Forwarding that unscaled floor to
        // the pool would leave the outcome to the pool's own credit model (`IOFT.OFTFeeDetail.feeAmountLD`
        // is signed, so a pool is not structurally required to credit at most what it is sent) and, on a
        // fee-model pool, would revert and retain the LayerZero packet forever while the executor's request
        // slot stays occupied (IL-8119). Reject terminally here instead, before any value moves — same
        // shape as CCIP (`CcipCrosschainDispatcher._returnAssets`).
        if (sendLD < _toLD(r_.minReturnSD)) {
            _rejectReturn(r_.requestId, ReturnRejectReason.BELOW_MINIMUM);
            return;
        }

        // Value safety: pass `minReturnSD` as the Stargate floor on destination credit. If the pool
        // would credit less — a fee/reward delta on a send that already met the floor above —
        // `_sendAssetUnlessShortCredit` sends nothing and returns a zero guid, and the branch below answers
        // RETURN_REJECTED(BELOW_MINIMUM) (IL-8452); a send above the live path credit is answered
        // RETURN_REJECTED(ABOVE_PATH_CREDIT) the same way (IL-8616). The security-critical "never deliver less than
        // minReturn" holds.
        bytes memory composeMsg = CrosschainMessages.encodeOutboundTransfer(
            OutboundTransfer({transferId: r_.requestId})
        );
        (bytes32 guid, uint256 amountSentLD, uint256 amountReceivedLD) = _sendAssetUnlessShortCredit(
            _executorChainIdImm(),
            sendLD,
            _toLD(r_.minReturnSD),
            composeMsg,
            ""
        );
        // The pool's fee would credit the executor below the manager's floor (IL-8452), or the send exceeds the
        // live path credit that `quoteOFT` silently caps (IL-8616; the library flags it with a non-zero
        // `amountSentLD`): reject terminally instead of reverting in `sendToken`, which would retain the
        // LayerZero packet.
        if (guid == bytes32(0)) {
            return
                _rejectReturn(
                    r_.requestId,
                    amountSentLD == 0 ? ReturnRejectReason.BELOW_MINIMUM : ReturnRejectReason.ABOVE_PATH_CREDIT
                );
        }

        trackedIdle -= _toSD(amountSentLD);
        recallConsumed[r_.requestId] = true;
        unchecked {
            ++stateVersion;
        }

        uint256 amountSentSD = _toSD(amountSentLD);
        uint256 amountReceivedSD = _toSD(amountReceivedLD);
        bytes memory payload = CrosschainMessages.encodeReturnStarted(
            ReturnStarted({
                requestId: r_.requestId,
                guid: guid,
                amountSentSD: amountSentSD,
                amountReceivedSD: amountReceivedSD,
                stateVersion: stateVersion,
                remoteBalanceSD: _remoteBalanceSD()
            })
        );
        _sendLzMessage(_executorChainIdImm(), payload, MSG_OPTION_TYPE, "");
        emit ReturnAssetsSent(r_.requestId, guid, amountSentSD, amountReceivedSD);
    }

    /// @dev Post-debit balance this dispatcher reports on `RETURN_STARTED` (shared decimals): tracked idle plus
    ///      every PRICED tracked vault, priced the same way as `observation()` (`TrackedVaultPricingLib.price`) so a
    ///      faulty vault counts as zero (the conservative direction) and never reverts the recall (IL-8602 / IL-8606).
    ///      Keeps the on-chain `VAULT_READ_GAS` budget for `convertToAssets`, unlike `observation()` (IL-8602 review
    ///      G-1): a position in a vault above it reports 0 here, so attest before a full recall (README).
    function _remoteBalanceSD() private view returns (uint256 total) {
        total = trackedIdle;
        uint256 len = trackedPositionVaults.length;
        for (uint256 i; i < len; ++i) {
            // An unpriced vault, or an absurd (> uint128 max) value, counts as zero so one faulty vault can never
            // overflow the sum and panic the recall (mirrors the CCIP `_valuation` bound).
            (uint256 assets, uint8 reason) = TrackedVaultPricingLib.price(
                trackedPositionVaults[i],
                address(this),
                _assetImm()
            );
            if (reason == TrackedVaultPricingLib.PRICED && assets <= type(uint128).max) total += _toSD(assets);
        }
    }

    /// @dev Terminal, non-reverting recall rejection: sends an authenticated `RETURN_REJECTED` to the
    ///      executor (which releases its request slot via `_onReturnRejected` -> `_finalizeReturn`) and
    ///      consumes the request so a LayerZero re-delivery of the original `RETURN_ASSETS_REQUEST` is a
    ///      no-op. The pool is never called on this path. The only revert this can produce is
    ///      `InsufficientNativeBudget` inside `_sendLzMessage` (`EXECUTOR_CHAIN_ID` is a path registered in
    ///      the constructor, so `UnknownChain` is unreachable) — the same revert the pre-existing
    ///      `NO_TRACKED_IDLE` rejection and the success path's own sends already carry on this lane, so
    ///      `_onReturnAssetsRequest` gains no revert path it did not have. `lzReceive` is atomic, so such a
    ///      revert discards `recallConsumed` along with everything else and LayerZero keeps the request
    ///      retryable to success once the dispatcher is topped up.
    function _rejectReturn(bytes32 requestId_, ReturnRejectReason reason_) private {
        bytes memory rejection = CrosschainMessages.encodeReturnRejected(
            ReturnRejected({requestId: requestId_, reason: reason_})
        );
        _sendLzMessage(_executorChainIdImm(), rejection, MSG_OPTION_TYPE, "");
        recallConsumed[requestId_] = true;
        emit ReturnAssetsRejected(requestId_, uint8(reason_));
    }

    /// @dev `raise_` is the authenticated RETRY's optional budget (0 = none). A retry can only RAISE: the maximum of the
    ///      stored raise and `raise_` is persisted (before the budget check, so it rolls back with a below-budget
    ///      revert) and every later run of the command uses `max(command.minExecutionGas, raisedBudget)` (IL-8625).
    function _onRetryCommand(bytes32 commandId_, uint64 raise_) private {
        CommandStatus st = commandStatus[commandId_];
        if (st == CommandStatus.SUCCEEDED || st == CommandStatus.CANCELLED) return; // idempotent
        if (st != CommandStatus.FAILED) revert CrosschainErrors.CommandNotFound(commandId_);

        StoredCommand storage sc = _storedCommands[commandId_];
        uint64 sequence = sc.sequence;
        if (_ignoreIfStale(commandId_, sequence)) return;

        _ensureReceiptBudget();
        uint8 msgType = sc.msgType;
        bytes memory data = sc.data;
        if (raise_ > sc.raisedBudget) sc.raisedBudget = raise_;

        commandStatus[commandId_] = CommandStatus.PENDING;
        _executeStoredCommand(commandId_, sequence, msgType, data);
    }

    function _onCancelCommand(bytes32 commandId_) private {
        CommandStatus st = commandStatus[commandId_];
        if (st == CommandStatus.CANCELLED || st == CommandStatus.SUCCEEDED) return; // idempotent
        if (st != CommandStatus.FAILED) revert CrosschainErrors.CommandNotFound(commandId_);

        uint64 sequence = _storedCommands[commandId_].sequence;
        if (_ignoreIfStale(commandId_, sequence)) return;

        _ensureReceiptBudget();
        // TTL fence (IL-8594), mirroring the CCIP dispatcher. A CANCEL retained by LayerZero can outlive an
        // executor-side `ABANDON_COMMAND_SEQUENCE_UNUSED`; if it landed after the replacement was sent but before
        // the replacement ran, it would still own the next sequence, consume it and its CANCELLED receipt would
        // retire the replacement (permanent `SequenceGap`). Past the deadline the command can never run, so it is
        // closed without consuming the sequence and the `EXPIRED` receipt tells the executor so: it frees the slot
        // only for this very command while FAILED and never moves its sequence mirror.
        bool expired = block.timestamp > CrosschainMessages.commandDeadline(commandId_);
        commandStatus[commandId_] = CommandStatus.CANCELLED;
        if (expired) {
            emit CancelCommandExpiredIgnored(commandId_, sequence);
        } else {
            // Cancel advances exactly one sequence and leaves the state version unchanged: it moves no value
            // (IL-8257), so its receipt carries the current version as evidence only.
            unchecked {
                ++nextCommandSequence;
            }
        }
        // Resolution receipt (reused ACK envelope, zero delta). The receipt states the resolution explicitly and
        // carries the unchanged `commandConfigEpoch`, so the executor never has to guess from a local flag whether
        // this ACK applied the command.
        _sendCommandAck(commandId_, sequence, 0, expired ? CommandResolution.EXPIRED : CommandResolution.CANCELLED);
        if (!expired) emit CommandCancelled(commandId_, sequence);
    }

    // ============================================================
    // Admin recall (timelocked exit for tracked idle, IL-8251)
    // ============================================================

    /// @notice Schedule a timelocked transfer of `amountSD_` tracked idle ASSET (shared decimals) to the
    ///         rescue admin.
    /// @dev Last-resort exit for idle value when the lane can no longer carry a recall home (Stargate pool
    ///      paused or retired, LayerZero path down, executor unable to send). Every other `trackedIdle`
    ///      debit needs an authenticated inbound message, and a generic rescue only reaches surplus above
    ///      the floor (`_afterRescueExecuted`), so without this the value would stay here with no Fusion
    ///      role able to move it. Full rescue delay and guardian veto apply.
    ///      Pays only the immutable `ADMIN()` at execution: if the ASSET issuer blocklists `ADMIN` on this chain,
    ///      a recipient-checking token (e.g. USDC) makes `executeAdminRecall` revert and tracked idle has no on-chain
    ///      exit until the lane recovers or the block is lifted, while a sender-only token (USDT, USDT0) lets it
    ///      succeed and freezes the tokens at `ADMIN` (IL-8807). Check the issuer's blocklist for `ADMIN` before
    ///      scheduling.
    function scheduleAdminRecall(uint256 amountSD_) external onlyRescueAdmin returns (uint256 rescueId) {
        return _scheduleForceResolve(_adminRecallCommitment(amountSD_));
    }

    /// @notice Transfer up to the scheduled amount of tracked idle ASSET to the rescue admin after the
    ///         rescue delay.
    /// @dev Clamped to the current `trackedIdle`, which may have shrunk during the delay. The debit lowers
    ///      the observed idle and the rescue floor by the same amount; no message is sent, because the lane
    ///      is presumed unusable (and `_sendLzMessage` would revert on it). `stateVersion` is deliberately
    ///      left unchanged: no receipt ever carries a version for this transition, so a bump would make the
    ///      next versioned receipt revert on the executor with `StateVersionGap`. The executor still counts
    ///      the value in `settledRemoteBalance` until the operator lowers it with the timelocked
    ///      `scheduleForceSetSettledBalance`; the recalled tokens return to the vault manually from the
    ///      admin. Observable through `ForceResolveConsumed` and the asset's `Transfer`.
    ///      Pays only the immutable `ADMIN()`; if the ASSET issuer blocklists `ADMIN` on this chain, a
    ///      recipient-checking token (e.g. USDC) reverts and tracked idle has no on-chain exit until the lane
    ///      recovers or the block is lifted, while a sender-only token (USDT, USDT0) succeeds and freezes the
    ///      tokens at `ADMIN` (IL-8807).
    function executeAdminRecall(uint256 rescueId_, uint256 amountSD_) external onlyRescueAdmin {
        _consumeForceResolve(rescueId_, _adminRecallCommitment(amountSD_));
        uint256 amountSD = _min(amountSD_, trackedIdle);
        trackedIdle -= amountSD;
        CrosschainVaultActionLib.transferAssetToAdmin(_toLD(amountSD));
    }

    // ============================================================
    // Force-untrack (timelocked write-off of an unpriceable tracked vault, IL-8602)
    // ============================================================

    /// @notice Schedule the removal of `vault_` from the tracked-position set regardless of its share balance.
    /// @dev For a tracked vault whose reads revert permanently (observations flag it in `vaultValued`). Full rescue
    ///      delay and guardian veto apply. Executing it WRITES OFF the position: it leaves every observation, so
    ///      the executor-side value must be lowered separately (`scheduleForceSetSettledBalance`). The shares stay
    ///      here. The IL-8556 rescue fence covers tracked AND allowlisted vaults, so a later generic rescue may
    ///      move them, if the vault heals, only once it is also off the deposit allowlist. While the vault stays
    ///      allowlisted, a new deposit into it would track it again.
    function scheduleForceUntrack(address vault_) external onlyRescueAdmin returns (uint256 rescueId) {
        if (!isTrackedVault[vault_]) revert CrosschainErrors.VaultNotTracked(vault_);
        return _scheduleForceResolve(_forceUntrackCommitment(vault_));
    }

    /// @notice Remove the vault from the tracked set after the rescue delay. Emits `TrackedVaultWrittenOff`.
    /// @dev Like `executeAdminRecall`, `stateVersion` is left unchanged (no receipt carries it); the tracked-set
    ///      hash changes, so attestations bound to the old set stop matching.
    function executeForceUntrack(uint256 rescueId_, address vault_) external onlyRescueAdmin {
        _consumeForceResolve(rescueId_, _forceUntrackCommitment(vault_));
        StargateDispatcherLib.forceUntrack(isTrackedVault, trackedPositionVaults, vault_);
    }

    function _forceUntrackCommitment(address vault_) private pure returns (bytes32) {
        return keccak256(abi.encode(bytes32("FORCE_UNTRACK_VAULT"), vault_));
    }

    /// @dev A `bytes32` domain tag rather than a string literal: identical separation, fewer bytes.
    function _adminRecallCommitment(uint256 amountSD_) private pure returns (bytes32) {
        return keccak256(abi.encode(bytes32("ADMIN_RECALL_IDLE"), amountSD_));
    }

    // ============================================================
    // Internal helpers
    // ============================================================

    function _sendCommandAck(
        bytes32 commandId_,
        uint64 sequence_,
        int256 valueDeltaSD_,
        CommandResolution resolution_
    ) private {
        bytes memory payload = CrosschainMessages.encodeCommandAck(
            CommandAck({
                commandId: commandId_,
                sequence: sequence_,
                stateVersion: stateVersion,
                dispatcherConfigEpoch: commandConfigEpoch,
                resolution: resolution_,
                valueDeltaSD: valueDeltaSD_
            })
        );
        _sendLzMessage(_executorChainIdImm(), payload, MSG_OPTION_TYPE, "");
    }

    function _sendCommandNack(bytes32 commandId_, uint64 sequence_) private {
        bytes memory payload = CrosschainMessages.encodeCommandNack(
            CommandNack({commandId: commandId_, sequence: sequence_})
        );
        _sendLzMessage(_executorChainIdImm(), payload, MSG_OPTION_TYPE, "");
    }

    /// @dev A FAILED record may be re-run or cancelled through the recall lane only while it still owns
    ///      the lane's next sequence.
    ///      Once the lane has moved past it — which happens only when the executor abandoned the command
    ///      with `ABANDON_COMMAND_SEQUENCE_UNUSED` and a replacement resolved at the same sequence — any
    ///      retry / cancel packet still naming it is a leftover retained by LayerZero. Acting on it would
    ///      advance `nextCommandSequence` a second time for one executor sequence (permanent `SequenceGap` on
    ///      every later command) and, for a retry, re-execute a command the operator abandoned (IL-7979).
    ///      Reverting would keep that packet retryable forever, so it is consumed as a no-op instead.
    ///      Called BEFORE `_ensureReceiptBudget` on purpose: a stale packet must be consumable with an
    ///      empty native budget.
    /// @return stale True when the caller must return without acting.
    function _ignoreIfStale(bytes32 commandId_, uint64 storedSequence_) private returns (bool stale) {
        uint64 next = nextCommandSequence;
        if (storedSequence_ == next) return false;
        emit StaleCommandResolutionIgnored(commandId_, storedSequence_, next);
        return true;
    }

    /// @dev Ensure the native budget can fund a worst-case receipt (an ACK) before the business action.
    function _ensureReceiptBudget() private view {
        bytes memory payload = CrosschainMessages.encodeCommandAck(
            CommandAck({
                commandId: bytes32(0),
                sequence: 0,
                stateVersion: 0,
                dispatcherConfigEpoch: 0,
                resolution: CommandResolution.SUCCEEDED,
                valueDeltaSD: 0
            })
        );
        bytes memory options = this.combineOptions(EXECUTOR_EID, MSG_OPTION_TYPE, "");
        MessagingFee memory fee = _quote(EXECUTOR_EID, payload, options, false);
        uint256 balance = address(this).balance;
        if (balance < fee.nativeFee) revert CrosschainErrors.InsufficientNativeBudget(balance, fee.nativeFee);
    }

    /// @dev Authoritative manager check: ask the VAULT which manager it is configured with, by executing
    ///      `plasmaVaultWithdrawManager()` in the vault's storage context through `UniversalReader.read`
    ///      (public on every PlasmaVault since IL-5094). Only call on a vault already in the tracked set —
    ///      it passed the allowlist's code/asset validation, and the answer is only as honest as the vault.
    ///      A vault without `read` reverts here, which is the right outcome. In practice that means a plain
    ///      ERC-4626 on the allowlist: `read` (IL-5094) predates `PlasmaVault.redeemFromRequest`, so no
    ///      PlasmaVault has the async path without it. Body in the linked
    ///      `CrosschainVaultActionLib.requireVaultWithdrawManager` (EIP-170).
    function _requireVaultWithdrawManager(address plasmaVault_, address withdrawManager_) private view {
        CrosschainVaultActionLib.requireVaultWithdrawManager(plasmaVault_, withdrawManager_);
    }

    /// @dev Add a vault to the tracked-position set on first live position (cap-checked before growth).
    function _addTrackedVault(address vault_) private {
        if (isTrackedVault[vault_]) return;
        if (trackedPositionVaults.length >= CrosschainConstants.MAX_TRACKED_POSITION_VAULTS) {
            revert CrosschainErrors.VaultsCapReached(CrosschainConstants.MAX_TRACKED_POSITION_VAULTS);
        }
        isTrackedVault[vault_] = true;
        trackedPositionVaults.push(vault_);
    }

    /// @dev Remove a vault from the tracked-position set only when its share balance is zero (a request cannot be
    ///      exercised without shares).
    function _maybeUntrack(address vault_) private {
        if (!isTrackedVault[vault_]) return;
        if (IERC20(vault_).balanceOf(address(this)) != 0) return;
        isTrackedVault[vault_] = false;
        uint256 len = trackedPositionVaults.length;
        for (uint256 i; i < len; ++i) {
            if (trackedPositionVaults[i] == vault_) {
                trackedPositionVaults[i] = trackedPositionVaults[len - 1];
                trackedPositionVaults.pop();
                return;
            }
        }
    }

    /// @dev Canonical tracked-position-set hash bound by attestations:
    ///      `keccak256(abi.encode(address(this), block.chainid, trackedPositionVaults))`. Body in the linked library
    ///      (EIP-170).
    function _trackedPositionSetHash() private view returns (bytes32) {
        return StargateDispatcherLib.trackedPositionSetHash(trackedPositionVaults);
    }

    /// @dev Pre-call ASSET snapshot for the non-worsening floor (IL-8640).
    function _beforeRescueExecuted() internal view override returns (uint256) {
        return IERC20(_assetImm()).balanceOf(address(this));
    }

    /// @dev Rescue may remove only untracked surplus and never worsens an already-underfunded idle ledger: the
    ///      ASSET balance must still cover `min(balanceBefore_, trackedIdle)` (IL-8640).
    function _afterRescueExecuted(uint256 balanceBefore_) internal override {
        // Body in the linked library (EIP-170).
        StargateDispatcherLib.checkRescueLedger(_assetImm(), balanceBefore_, _toLD(trackedIdle));
    }

    /// @dev Reads `ASSET` through one shared JUMP target instead of inlining the immutable at every use (EIP-170).
    function _assetImm() private view returns (address) {
        return ASSET;
    }

    /// @dev Reads `EXECUTOR_CHAIN_ID` through one shared JUMP target instead of inlining the immutable (EIP-170).
    function _executorChainIdImm() private view returns (uint256) {
        return EXECUTOR_CHAIN_ID;
    }

    function _min(uint256 a_, uint256 b_) private pure returns (uint256) {
        return a_ < b_ ? a_ : b_;
    }
}

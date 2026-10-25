// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IPlasmaVault} from "../../interfaces/IPlasmaVault.sol";
import {CcipAppBase} from "./base/CcipAppBase.sol";
import {CcipClient} from "./interfaces/CcipClient.sol";
import {CcipRouteConfig} from "./interfaces/ICcipCrosschain.sol";
import {CcipMessages, CcipMsgType} from "./lib/CcipMessages.sol";
import {CcipDecimalsLib} from "./lib/CcipDecimalsLib.sol";
import {BusinessAction, CommandStatus, CommandResolution, CrosschainConstants} from "../lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../lib/CrosschainErrors.sol";
import {Command, CrosschainMessages} from "../lib/CrosschainMessages.sol";
import {CrosschainVaultActionLib} from "../lib/CrosschainVaultActionLib.sol";
import {TrackedVaultPricingLib} from "../lib/TrackedVaultPricingLib.sol";
import {CcipDispatcherLib} from "./lib/CcipDispatcherLib.sol";
import {RescueModule} from "../lib/RescueModule.sol";
import {ICcipDispatcherLibraryAbi} from "./ICcipDispatcherLibraryAbi.sol";
import {PlasmaVaultStorageLib} from "../../libraries/PlasmaVaultStorageLib.sol";

/// @notice Mirror of the WithdrawManager request view (`WithdrawManager.WithdrawRequestInfo`), field for field, so the
///         dispatcher can decode `requestInfo` without importing the manager.
/// @dev `shares` is the manager's outstanding request, `endWithdrawWindowTimestamp` the end of the window in which it
///      can be redeemed, `canWithdraw` whether that window is open now, `withdrawWindowInSeconds` the window length.
struct CcipWithdrawRequestInfo {
    uint256 shares;
    uint256 endWithdrawWindowTimestamp;
    bool canWithdraw;
    uint256 withdrawWindowInSeconds;
}

/// @notice The two WithdrawManager entry points the dispatcher calls on a remote vault's manager.
interface ICcipWithdrawManager {
    /// @notice Registers (replaces) the caller's withdraw request for `shares_` vault shares.
    function requestShares(uint256 shares_) external;
    /// @notice The manager's stored request of `account_`.
    function requestInfo(address account_) external view returns (CcipWithdrawRequestInfo memory);
}

/// @notice Atomic CCIP dispatcher snapshot used to build a balance attestation from one eth_call.
struct CcipObservation {
    uint256 accountedBalance;
    uint256 trackedIdle;
    uint256 queuedTokenAmount;
    uint64 stateVersion;
    uint64 commandConfigEpoch;
    bytes32 trackedPositionSetHash;
    /// @dev IL-8602: number of tracked vaults whose `balanceOf` / `asset` / `convertToAssets` read failed, whose
    ///      `convertToAssets` exceeds `type(uint128).max` or whose `asset()` is not `ASSET` (IL-8645). Their value
    ///      is NOT in `accountedBalance`.
    uint256 unpricedCount;
    /// @dev IL-8602: 2 bits per `trackedVaults` index (0 priced, 1 `balanceOf` failed, 2 `convertToAssets` failed or
    ///      returned a value above `type(uint128).max`, which is reported as unpriced rather than overflowing,
    ///      3 = `asset()` reverted, malformed or != `ASSET` (IL-8645)).
    uint256 unpricedCodes;
}

/// @title CcipCrosschainDispatcher
/// @notice Remote-chain side of the CCIP crosschain lane: holds the bridged asset, runs the executor's sequenced
///         commands (deposit, redeem, request shares, redeem from request, vault allowlist updates) against the
///         allowlisted and tracked ERC-4626 vaults, and answers with receipts, balance reports and token returns.
/// @dev Every non-expired command delivered with at least its gas budget runs through `runStoredCommand`, a
///      self-call, so a business failure is caught, NACKed to the executor and never blocks the CCIP message.
///      An expired command is NACKed without the self-call, and a delivery below the budget reverts on the OffRamp. `accountedBalance` is the value the executor attests: idle asset
///      (`trackedIdle`), tokens queued for return and the priced tracked vault positions. Inbound CCIP messages enter
///      through `ccipReceive` under the reentrancy guard.
contract CcipCrosschainDispatcher is CcipAppBase, RescueModule, ICcipDispatcherLibraryAbi {
    error OnlyFactory();
    error InvalidTokenDelivery();
    error InvalidExecutorChain(uint256 chainId);
    error VaultNotAllowed(address vault);
    error InvalidSequence(uint64 expected, uint64 actual);
    error UnsupportedAction(uint8 action);
    /// @dev Raised only by the rescue post-condition (IL-8640): `available` is the post-rescue ASSET balance,
    ///      `requested` is min(pre-rescue ASSET balance, tracked ledger in LD).
    error InsufficientTrackedIdle(uint256 available, uint256 requested);
    error MinimumNotMet(uint256 actual, uint256 minimum);
    error AccountingDeltaOverflow(uint256 amount);
    error InvalidVault(address vault);
    error VaultsCapReached(uint256 maximum);
    error WithdrawManagerMismatch(address withdrawManager, address vault);
    /// @dev The vault reports no manager in either slot, or the command named `address(0)` (IL-8608).
    error WithdrawManagerUnresolved(address vault);
    error RequestSharesFeeExceeded(address vault, uint256 deducted, uint256 shares, uint256 maxFeeShares);
    error AssetCannotPayCcipFees();
    error OnlySelf();
    error InvalidConfigEpoch(uint64 expected, uint64 received);
    error CommandNotFailed(bytes32 commandId);
    error CommandCommitmentMismatch(bytes32 commandId);
    error InvalidDecimals(uint8 localDecimals, uint8 sharedDecimals);
    /// @notice `localDecimals - sharedDecimals` exceeds 18 (conversion rate would exceed 1e18).
    error DecimalsGapTooLarge(uint8 localDecimals, uint8 sharedDecimals);
    error ResponseQueueFull(uint256 maximum);
    /// @dev A value-neutral response (`BALANCE_REPORT`, `COMMAND_ACK`) was refused because `live` responses are
    ///      queued and the last `RESERVED_FOR_VALUE_MOVING` slots belong to the other response types (IL-8583).
    error ResponseQueueNeutralCapReached(uint256 live, uint256 cap);
    error NoQueuedResponse();
    error VaultsAlreadyInitialized();
    error ZeroBusinessAmount();
    error VaultNotTracked(address vault);

    /// @notice One queued dispatcher -> executor response.
    /// @dev `amountLD` is the bridged token amount in LOCAL ASSET decimals (it is what the CCIP message carries).
    ///      Sibling accounting values are SHARED decimals: `queuedTokenAmount`, `trackedIdle` and the `amount`
    ///      of `InboundSettled` / `ReturnQueued`. Convert with `_toSDFloor` / `_toLD` (a factor
    ///      `DECIMAL_CONVERSION_RATE`, invisible only when local and shared decimals are equal).
    struct QueuedResponse {
        bytes data;
        uint256 amountLD;
    }

    address public immutable FACTORY;
    address public immutable ASSET;
    bytes32 public immutable ASSET_ID;
    uint256 public immutable EXECUTOR_CHAIN_ID;
    uint8 public immutable LOCAL_DECIMALS;
    uint8 public immutable SHARED_DECIMALS;
    uint256 public immutable DECIMAL_CONVERSION_RATE;
    uint256 public constant MAX_TRACKED_VAULTS = 32;
    /// @notice Hard cap of live queued responses. Only a response that moves value, rejects a recall or NACKs a
    ///         command can use the last `RESERVED_FOR_VALUE_MOVING` slots (IL-8583).
    uint256 public constant MAX_QUEUED_RESPONSES = 64;
    /// @notice Slots withheld from the value-neutral `BALANCE_REPORT` / `COMMAND_ACK` responses, so a stalled queue
    ///         can still absorb `TRANSFER_SETTLED`, `RETURN_TRANSFER`, `RETURN_REJECTED` and `COMMAND_NACK` (IL-8583).
    uint256 public constant RESERVED_FOR_VALUE_MOVING = 8;

    /// @dev Chainlink `RateLimiter.TokenMaxCapacityExceeded(uint256,uint256,address)`: permanent until the pool
    ///      admin raises the bucket capacity, unlike the transient `TokenRateLimitReached`.
    bytes4 private constant TOKEN_MAX_CAPACITY_EXCEEDED_SELECTOR = 0x1a76572a;

    uint256 public trackedIdle;
    /// @notice Number of value-moving transitions reported to the executor (IL-8257): it is bumped exactly once
    ///         per `TRANSFER_SETTLED` and once per `RETURN_TRANSFER` response that stands (one unwound as
    ///         `ABOVE_POOL_CAPACITY`, IL-8553, does not bump it), and nowhere else.
    ///         Value-neutral responses never bump it: `BALANCE_REPORT` and `COMMAND_ACK` carry the CURRENT
    ///         value as evidence, `COMMAND_NACK` and `RETURN_REJECTED` carry none. So a stalled response queue
    ///         that holds only value-neutral responses never makes the executor's frontier
    ///         (`lastRemoteStateVersion`) lag `stateVersion`. The executor advances its frontier only on the
    ///         two value-moving responses, one version at a time.
    uint64 public stateVersion;
    uint64 public nextCommandSequence;
    uint64 public commandConfigEpoch;
    mapping(address => bool) public isAllowedVault;
    mapping(address => bool) public isTrackedVault;
    mapping(address => uint256) private _trackedVaultIndexPlusOne;
    address[] public trackedVaults;
    mapping(bytes32 => bool) public processedOperation;
    mapping(bytes32 => CommandStatus) public commandStatus;
    mapping(bytes32 => bytes32) public commandCommitment;
    mapping(bytes32 => bytes) private _storedCommands;
    mapping(uint64 => QueuedResponse) private _queuedResponses;
    uint64 public responseQueueHead;
    uint64 public responseQueueTail;
    uint256 public queuedTokenAmount;
    /// @notice Whether the factory has already seeded the initial allowlist. `configureVaults` is a
    ///         one-shot bootstrap: a second call would bump `commandConfigEpoch` outside the sequenced lane, and
    ///         the executor's mirror would then only catch up through a NACK-and-cancel round (the cancel
    ///         receipt carries this epoch, R-01) or the timelocked `REALIGN_COMMAND_LANE` rescue
    ///         (IL-7970). Hence one-shot (audit M-7).
    bool public vaultsInitialized;
    /// @dev Id of the most recent `BALANCE_REPORT` queued by `_sendBalanceMessage`. It is live while its record
    ///      still exists (a dispatch or a drop deletes the record), which is when a new request coalesces into it.
    uint64 private _queuedBalanceReportId;

    event InboundSettled(bytes32 operationId, uint256 amount, uint64 stateVersion);
    event ReturnQueued(bytes32 operationId, uint256 amount, uint64 responseId);
    event ReturnRejected(bytes32 operationId, uint8 reason, uint64 responseId);
    /// @notice A recall exceeded the local token pool's outbound rate-limit capacity and was answered
    ///         `RETURN_REJECTED(ABOVE_POOL_CAPACITY)` instead of being delivered (IL-8553). `responseId` is the
    ///         dropped queue entry, also announced by `ResponseSkipped`.
    event ReturnAboveLocalPoolCapacity(bytes32 operationId, uint256 amount, uint256 capacity, uint64 responseId);
    event CommandSucceeded(bytes32 commandId, uint64 sequence, int256 valueDelta);
    event CommandFailed(bytes32 commandId, uint64 sequence);
    event CommandCancelled(bytes32 commandId, uint64 sequence);
    /// @notice A CANCEL_COMMAND arrived after its command's deadline (IL-8594): the command is closed (CANCELLED) without
    ///         consuming its sequence and, unless the lane already passed that sequence, answered with an `EXPIRED`
    ///         receipt. Routine after every post-TTL manager cancel, so not an alert by itself; the alert is the
    ///         executor's `LateReceiptRetiredPendingReplacement`.
    event CancelCommandExpiredIgnored(uint256 srcChainId, bytes32 commandId, uint64 sequence, uint64 deadline);
    event VaultAllowed(address vault, bool allowed);
    /// @notice Emitted after every allowlist change (factory bootstrap and sequenced `UPDATE_VAULTS`) with the
    ///         NEW `commandConfigEpoch`, the mode flags and the number of vaults in the command. The per-vault
    ///         changes are the `VaultAllowed` events in the same transaction.
    event VaultsConfigured(uint64 commandConfigEpoch, bool replace, bool allowed, uint256 count);
    /// @notice Tracked-position set membership changed: `vault` was appended to `trackedVaults`.
    event VaultTracked(address vault);
    /// @notice Tracked-position set membership changed: `vault` was removed from `trackedVaults`. Removal is
    ///         swap-and-pop, so the order of `trackedVaults` (and thus `trackedPositionSetHash()`) changes;
    ///         read `trackedVaults` / `trackedPositionSetHash()` at this block for the exact ordered set.
    event VaultUntracked(address vault);
    /// @notice A tracked vault could not be priced (a `balanceOf`, `asset()` or `convertToAssets` read reverted or
    ///         returned malformed data, `convertToAssets` exceeded `type(uint128).max`, or `asset()` is not `ASSET`)
    ///         while a response was built, so its value is missing from that response's remote balance (IL-8602).
    ///         `reason` 1 = `balanceOf`, 2 = `convertToAssets`, 3 = `asset()` drift (IL-8645). The wire format
    ///         carries no flag: attesters must watch this event and `observation().unpricedCount`.
    event TrackedVaultUnpriced(address vault, uint8 reason);
    /// @notice A `REQUEST_SHARES` command ran; `pendingShares` is the vault's WithdrawManager outstanding request
    ///         for this dispatcher, read back after the call (the new value replaces the old one, it does not add).
    ///         `feeShares` is the MEASURED drop of this contract's vault-share balance across `requestShares`.
    event SharesRequested(address vault, uint256 pendingShares, uint256 feeShares);
    /// @notice A `REDEEM_FROM_REQUEST` command burned `sharesRedeemed` of the outstanding request of `vault`
    ///         and credited `assetsDeltaSD` (measured, floored, shared decimals) to `trackedIdle`.
    event RedeemedFromRequest(address vault, uint256 sharesRedeemed, uint256 assetsDeltaSD);
    /// @notice A response was appended to the queue. `amountLD` is the carried token amount in LOCAL ASSET
    ///         decimals (0 for a message-only response); `queuedTokenAmount` and the `amount` of `ReturnQueued`
    ///         are SHARED decimals.
    event ResponseQueued(uint64 responseId, CcipMsgType messageType, uint256 amountLD);
    event ResponseDispatched(uint64 responseId, bytes32 messageId);
    /// @notice A queued response was dropped without being sent. `amountLD` is its token amount in LOCAL ASSET
    ///         decimals (re-credited to `trackedIdle` in SHARED decimals).
    event ResponseSkipped(uint64 responseId, uint256 amountLD);
    /// @notice A `BALANCE_REQUEST` was folded into the still-undispatched `BALANCE_REPORT` `responseId`: its
    ///         payload now carries the current balance and `stateVersion` and no new entry was appended (IL-8583).
    event ResponseCoalesced(uint64 responseId);

    modifier onlyFactory() {
        _checkFactory();
        _;
    }

    function _checkFactory() private view {
        if (msg.sender != FACTORY) revert OnlyFactory();
    }

    constructor(
        address router_,
        address factory_,
        address asset_,
        bytes32 assetId_,
        uint8 sharedDecimals_,
        uint256 executorChainId_,
        CcipRouteConfig memory executorRoute_,
        address rescueAdmin_,
        address rescueGuardian_,
        uint256 rescueDelay_
    ) CcipAppBase(router_) RescueModule(rescueAdmin_, rescueGuardian_, rescueDelay_) {
        if (factory_ == address(0) || asset_ == address(0)) revert CcipZeroAddress();
        FACTORY = factory_;
        ASSET = asset_;
        ASSET_ID = assetId_;
        uint8 localDecimals = IERC20Metadata(asset_).decimals();
        if (sharedDecimals_ > localDecimals) revert InvalidDecimals(localDecimals, sharedDecimals_);
        if (localDecimals - sharedDecimals_ > 18) revert DecimalsGapTooLarge(localDecimals, sharedDecimals_);
        LOCAL_DECIMALS = localDecimals;
        SHARED_DECIMALS = sharedDecimals_;
        DECIMAL_CONVERSION_RATE = 10 ** (localDecimals - sharedDecimals_);
        EXECUTOR_CHAIN_ID = executorChainId_;
        if (executorRoute_.feeToken == asset_) revert AssetCannotPayCcipFees();
        _registerCcipRoute(executorChainId_, executorRoute_);
    }

    /// @notice Synchronize the executor lane's timelocked delivery policy.
    /// @dev Route identity is absent from this ABI and therefore cannot change; only the factory may call.
    function syncRoutePolicy(address feeToken_, uint256 gasLimitsAndFlags_, uint256 maxFee_) external onlyFactory {
        if (feeToken_ == _assetImm()) revert AssetCannotPayCcipFees();
        _updateCcipRoutePolicy(_executorChainIdImm(), feeToken_, gasLimitsAndFlags_, maxFee_);
    }

    /// @notice One-shot bootstrap of the initial deposit allowlist, called by the factory immediately
    ///         after CREATE3 deployment. Every later change MUST go through the sequenced command lane so
    ///         `commandConfigEpoch` stays in lockstep with the executor's mirror (audit M-7).
    function configureVaults(address[] calldata vaults_, bool allowed_) external onlyFactory {
        if (vaultsInitialized) revert VaultsAlreadyInitialized();
        vaultsInitialized = true;
        _configureVaults(vaults_, allowed_, false);
        ++commandConfigEpoch;
        emit VaultsConfigured(commandConfigEpoch, false, allowed_, vaults_.length);
    }

    function _handleCcipMessage(uint256 srcChainId_, CcipClient.Any2EVMMessage memory message_) internal override {
        if (srcChainId_ != _executorChainIdImm()) revert InvalidExecutorChain(srcChainId_);
        (CcipMsgType messageType, bytes memory data) = CcipMessages.decode(message_.data);
        if (messageType == CcipMsgType.OUTBOUND_TRANSFER) {
            _receiveOutbound(message_, data);
        } else if (messageType == CcipMsgType.RETURN_REQUEST) {
            _returnAssets(data);
        } else if (messageType == CcipMsgType.COMMAND || messageType == CcipMsgType.UPDATE_VAULTS) {
            _executeCommand(data);
        } else if (messageType == CcipMsgType.RETRY_COMMAND) {
            _retryCommand(abi.decode(data, (bytes32)));
        } else if (messageType == CcipMsgType.CANCEL_COMMAND) {
            _cancelCommand(abi.decode(data, (bytes32)));
        } else if (messageType == CcipMsgType.BALANCE_REQUEST) {
            // Value-neutral (IL-8257): the report carries the CURRENT version as evidence and does not bump it.
            _sendBalanceMessage(stateVersion);
        } else {
            revert CcipMessages.InvalidMessageType(uint8(messageType));
        }
    }

    function _receiveOutbound(CcipClient.Any2EVMMessage memory message_, bytes memory data_) private {
        // Exactly one ASSET entry, but its amount may be ZERO: a CCIP 2.0 pool fee plus decimal downscaling can
        // deliver nothing for a positive send (IL-8635, mirror of the RETURN_TRANSFER fix). It settles as a zero
        // credit, so the executor closes the outbound and reports the loss (SettledCreditShortfall); a revert
        // would leave the message FAILED forever and the outbound in flight until a timelocked force-resolve.
        if (message_.destTokenAmounts.length != 1 || message_.destTokenAmounts[0].token != _assetImm()) {
            revert InvalidTokenDelivery();
        }
        bytes32 operationId = abi.decode(data_, (bytes32));
        if (processedOperation[operationId]) revert CcipMessageAlreadyProcessed(operationId);
        processedOperation[operationId] = true;
        // The delivered amount is an EXTERNAL value: a fee-taking token pool (or any asset whose local
        // decimals exceed the shared ones) can credit sub-precision dust. Flooring keeps the dust as
        // untracked surplus recoverable through rescue; reverting would strand the delivery (audit M-3).
        uint256 amount = _toSDFloor(message_.destTokenAmounts[0].amount);
        trackedIdle += amount;
        uint64 version = ++stateVersion;
        uint256 remoteBalance = _reportedBalance();
        _queueResponse(CcipMsgType.TRANSFER_SETTLED, abi.encode(operationId, amount, remoteBalance, version), 0);
        emit InboundSettled(operationId, amount, version);
    }

    /// @dev Answers a recall with a `RETURN_TRANSFER` or a `RETURN_REJECTED`. When the response lands at the
    ///      queue head its send is attempted immediately; if the token pool reverts `TokenMaxCapacityExceeded`
    ///      (a permanent condition, IL-8553) the queue entry and the `trackedIdle` debit are unwound and the
    ///      recall is rejected with `ABOVE_POOL_CAPACITY`, so no value moves and `stateVersion` is not bumped.
    ///      A transient `TokenRateLimitReached`, any other send failure, or an occupied queue head keeps the
    ///      recall queued for `flushResponse` as before.
    /// @dev The request carries the `deadline` the executor stamped (`createdAt + TRANSFER_STALENESS_MAX`, IL-8590).
    ///      A request executed after it (CCIP delivery is permissionless, so a stuck message can be executed
    ///      arbitrarily late) is rejected with `EXPIRED` before any value moves: the executor has by then declared
    ///      the recall stale and may have cancelled it and cleared its clock. The operation is still marked
    ///      processed, so the expired message cannot be replayed, and `stateVersion` is not bumped (a rejection
    ///      carries no version). The deadline is inclusive: a request executed at exactly `deadline` is honoured.
    function _returnAssets(bytes memory data_) private {
        (bytes32 operationId, uint256 requested, uint256 maxAccounted, uint256 minReturn, uint256 deadline) = abi
            .decode(data_, (bytes32, uint256, uint256, uint256, uint256));
        if (processedOperation[operationId]) revert CcipMessageAlreadyProcessed(operationId);
        processedOperation[operationId] = true;
        if (block.timestamp > deadline) {
            _rejectReturn(operationId, CcipReturnRejectReason.EXPIRED);
            return;
        }
        uint256 amount = requested > trackedIdle ? trackedIdle : requested;
        if (amount > maxAccounted) amount = maxAccounted;
        if (maxAccounted == 0) {
            _rejectReturn(operationId, CcipReturnRejectReason.INVALID_BOUND);
            return;
        }
        if (amount == 0) {
            _rejectReturn(operationId, CcipReturnRejectReason.NO_TRACKED_IDLE);
            return;
        }
        if (amount < minReturn) {
            _rejectReturn(operationId, CcipReturnRejectReason.BELOW_MINIMUM);
            return;
        }
        // The debit is applied first so `_accountedBalance()` is never overstated while the tokens leave; it is
        // restored below if the head send fails permanently. The version is only committed once the recall is
        // known to stand, so a rejected recall never leaves a gap in the executor's contiguous frontier.
        trackedIdle -= amount;
        uint64 version = stateVersion + 1;
        uint64 responseId = _enqueueResponse(
            CcipMsgType.RETURN_TRANSFER,
            abi.encode(operationId, amount, _reportedBalance(), version),
            _toLD(amount)
        );
        if (responseQueueHead == responseId) {
            (bool ok, bytes memory reason) = _tryDispatchHead(responseId);
            if (!ok && reason.length >= 100 && bytes4(reason) == TOKEN_MAX_CAPACITY_EXCEEDED_SELECTOR) {
                uint256 capacity;
                assembly ("memory-safe") {
                    capacity := mload(add(reason, 36))
                }
                // Nothing left the contract: drop the sole queue entry (re-crediting `trackedIdle`, which undoes
                // the debit above) but keep the tail, so the id is never reused and indexers see the drop.
                _dropHeadResponse(responseId);
                emit ReturnAboveLocalPoolCapacity(operationId, amount, capacity, responseId);
                _rejectReturn(operationId, CcipReturnRejectReason.ABOVE_POOL_CAPACITY);
                return;
            }
        }
        stateVersion = version;
        emit ReturnQueued(operationId, amount, responseId);
    }

    function _rejectReturn(bytes32 operationId_, CcipReturnRejectReason reason_) private {
        uint64 responseId = _queueResponse(CcipMsgType.RETURN_REJECTED, abi.encode(operationId_, uint8(reason_)), 0);
        emit ReturnRejected(operationId_, uint8(reason_), responseId);
    }

    function _executeCommand(bytes memory data_) private {
        (CcipMsgType storedType, Command memory command, bytes memory extra) = abi.decode(
            data_,
            (CcipMsgType, Command, bytes)
        );
        if (command.sequence != nextCommandSequence) revert InvalidSequence(nextCommandSequence, command.sequence);
        if (commandStatus[command.commandId] != CommandStatus.NONE) {
            revert CcipMessageAlreadyProcessed(command.commandId);
        }
        bytes32 commitment = keccak256(data_);
        commandCommitment[command.commandId] = commitment;
        _storedCommands[command.commandId] = data_;
        _runCommand(storedType, command, extra);
    }

    /// @dev Runs a stored command inside the gas-bounded self-call; shared by first delivery and retry.
    function _runCommand(CcipMsgType storedType, Command memory command, bytes memory extra) private {
        commandStatus[command.commandId] = CommandStatus.PENDING;
        // The command deadline is checked FIRST (IL-8625): an expired command can never run, so it skips the budget
        // check and the business call and is NACKed with enough gas to send the NACK; the manager's CANCEL then
        // gets the IL-8594 `EXPIRED` receipt. Otherwise a command whose budget can never be delivered would fail on the
        // OffRamp forever and only the admin's ABANDON could free the lane. The deadline stays inclusive (`>`).
        if (block.timestamp > CrosschainMessages.commandDeadline(command.commandId)) {
            _recordFailure(command);
            return;
        }
        _requireCommandGas(command.minExecutionGas);
        try
            this.runStoredCommand{gas: gasleft() - CrosschainConstants.COMMAND_CATCH_RESERVE_GAS}(
                storedType,
                command,
                extra
            )
        returns (int256 delta) {
            _completeCommand(command, delta);
        } catch {
            // IL-8625: the delivery had at least the command's budget, so whatever the business call did (a decodable
            // error, an empty revert, out-of-gas, `InsufficientGasForVaultRead`) is a business failure. Only the
            // gas for the NACK itself is guarded.
            _recordFailure(command);
        }
    }

    /// @dev FAILED + NACK, shared by the caught business failure and the expired-command short cut. Only the gas for
    ///      the NACK itself is guarded (`MIN_NACK_GAS`).
    function _recordFailure(Command memory command) private {
        if (gasleft() < CrosschainConstants.MIN_NACK_GAS) {
            revert CrosschainErrors.InsufficientGasForNack(gasleft(), CrosschainConstants.MIN_NACK_GAS);
        }
        commandStatus[command.commandId] = CommandStatus.FAILED;
        _sendCommandNack(command.commandId, command.sequence);
        emit CommandFailed(command.commandId, command.sequence);
    }

    /// @dev IL-8625: the command carries its gas budget (`minExecutionGas`, derived by the executor from the
    ///      route's gas and the payload size, `CrosschainMessages.commandGasBudget`, and part of the committed bytes). A delivery with less gas reverts, the
    ///      message fails on the OffRamp and is re-run by manual execution with more gas; at or above the budget every
    ///      failure of the business call is a business failure. The stored budget is raised to
    ///      `COMMAND_EXECUTION_MIN_GAS` defensively. Called directly before the capped self-call, after the storage
    ///      writes (the revert rolls them back, as on Stargate): checked earlier, those writes (about 22k per stored payload
    ///      word, up to ~1.1M for 32 vaults, which the budget formula accounts for) would eat into
    ///      the budget and a large UPDATE_VAULTS could underflow `gasleft() - COMMAND_CATCH_RESERVE_GAS` (Panic 0x11).
    function _requireCommandGas(uint64 minExecutionGas_) private view {
        uint256 required = minExecutionGas_;
        if (required < CrosschainConstants.COMMAND_EXECUTION_MIN_GAS) {
            required = CrosschainConstants.COMMAND_EXECUTION_MIN_GAS;
        }
        if (gasleft() < required) revert CrosschainErrors.InsufficientGasForCommand(gasleft(), required);
    }

    /// @notice Runs one executor command (or a vault-allowlist update) against the allowlisted (DEPOSIT) or tracked
    ///         (REDEEM, REQUEST_SHARES, REDEEM_FROM_REQUEST) vaults.
    /// @dev Self-call only: any other caller reverts `OnlySelf`. `_runCommand` calls it through `this` with a capped
    ///      gas stipend so that a revert is caught and turned into a NACK. It re-checks the command deadline
    ///      (encoded in the high 64 bits of `commandId`, `CommandExpired` after it) and the config epoch
    ///      (`InvalidConfigEpoch` unless `commandConfigEpoch` matches the one the command was built under), then
    ///      applies `UPDATE_VAULTS` or a business action. Returns the signed change of the tracked ledger in shared
    ///      decimals.
    /// @param storedType_ `COMMAND` or `UPDATE_VAULTS`.
    /// @param command_ The command as delivered.
    /// @param extra_ ABI-encoded `(address[] vaults, bool allowed, bool replace)` for `UPDATE_VAULTS`, else unused.
    function runStoredCommand(
        CcipMsgType storedType_,
        Command calldata command_,
        bytes calldata extra_
    ) external returns (int256 delta) {
        if (msg.sender != address(this)) revert OnlySelf();
        // Expired work is NACKed, never run: a FAILED OffRamp message (or a retry) outliving an executor-side
        // abandon would otherwise execute the abandoned intent (IL-8255). `_runCommand` already checks the deadline
        // before the budget and this self-call and NACKs directly (IL-8625), so this check is defence in depth.
        if (block.timestamp > CrosschainMessages.commandDeadline(command_.commandId)) {
            revert CrosschainErrors.CommandExpired(command_.commandId);
        }
        if (command_.commandConfigEpoch != commandConfigEpoch) {
            revert InvalidConfigEpoch(commandConfigEpoch, command_.commandConfigEpoch);
        }
        if (storedType_ == CcipMsgType.UPDATE_VAULTS) {
            (address[] memory vaults, bool allowed, bool replace) = abi.decode(extra_, (address[], bool, bool));
            // Vaults leaving the allowlist are swept into idle inside this gas-bounded self-call (IL-8784): the
            // redeemed assets are credited to `trackedIdle`, the position leaves the tracked set (value-neutral).
            trackedIdle += _toSDFloor(_configureVaults(vaults, allowed, replace));
            ++commandConfigEpoch;
            emit VaultsConfigured(commandConfigEpoch, replace, allowed, vaults.length);
            return 0;
        }
        if (storedType_ != CcipMsgType.COMMAND) revert CcipMessages.InvalidMessageType(uint8(storedType_));
        return _runBusinessCommand(command_);
    }

    function _runBusinessCommand(Command memory command) private returns (int256 delta) {
        if (command.action == uint8(BusinessAction.DEPOSIT)) {
            (address vault, uint256 amountSD, uint256 minShares) = CrosschainMessages.decodeDepositAction(
                command.actionData
            );
            if (!isAllowedVault[vault]) revert VaultNotAllowed(vault);
            // IL-8645: admission checked `asset()` once; re-assert before any approval. Redeems are not gated.
            address actualAsset = IERC4626(vault).asset();
            if (actualAsset != _assetImm()) revert CrosschainErrors.VaultAssetDrifted(vault, actualAsset);
            if (amountSD > trackedIdle) amountSD = trackedIdle;
            uint256 amount = _toLD(amountSD);
            // A zero-amount deposit would consume a sequence number for no work (and silently succeed
            // whenever `minShares == 0`). Fail it so the operator sees a NACK instead (audit L-2).
            if (amount == 0) revert ZeroBusinessAmount();
            uint256 beforeBalance = IERC20(_assetImm()).balanceOf(address(this));
            // Measured share delta, not the vault's reported return value (IL-8601).
            uint256 shares = CrosschainVaultActionLib.depositScoped(_assetImm(), vault, amount);
            if (shares < minShares) revert MinimumNotMet(shares, minShares);
            uint256 spent = beforeBalance - IERC20(_assetImm()).balanceOf(address(this));
            // Debit the tracked ledger conservatively: round the measured spend UP so truncation can
            // never leave `trackedIdle` claiming value the dispatcher no longer holds.
            uint256 spentSD = _toSDCeil(spent);
            if (spentSD > trackedIdle) spentSD = trackedIdle;
            trackedIdle -= spentSD;
            delta = -_toInt256(spentSD);
        } else if (command.action == uint8(BusinessAction.REDEEM)) {
            (address vault, uint256 shares, uint256 minAssetsSD) = CrosschainMessages.decodeRedeemAction(
                command.actionData
            );
            // Gate on the TRACKED set, as on Stargate: the redeem unwinds a position, it is not a deposit.
            if (!isTrackedVault[vault]) revert VaultNotTracked(vault);
            // Clamp to the position actually held so an over-request degrades to a partial redeem instead
            // of a NACK that then needs the recall lane (matches the Stargate dispatcher, audit L-4).
            uint256 shareBalance = IERC20(vault).balanceOf(address(this));
            if (shares > shareBalance) shares = shareBalance;
            if (shares == 0) revert ZeroBusinessAmount();
            uint256 beforeBalance = IERC20(_assetImm()).balanceOf(address(this));
            uint256 assets = IERC4626(vault).redeem(shares, address(this), address(this));
            uint256 receivedSD;
            (delta, receivedSD) = _creditReceived(beforeBalance, minAssetsSD, assets);
        } else if (command.action == uint8(BusinessAction.REQUEST_SHARES)) {
            (address withdrawManager, address vault, uint256 shares, uint256 maxFeeShares) = CrosschainMessages
                .decodeRequestSharesAction(command.actionData);
            // Gate on the TRACKED set, not the allowlist: a vault removed from the deposit allowlist may
            // still hold a live position that has to be unwound (matches Stargate, audit L-3).
            if (!isTrackedVault[vault]) revert VaultNotTracked(vault);
            _requireVaultWithdrawManager(vault, withdrawManager);
            uint256 balance = IERC20(vault).balanceOf(address(this));
            // Not a slippage bound: the dispatcher holds fewer shares than the request names. Same error as Stargate.
            if (shares > balance) revert CrosschainErrors.RequestSharesUnavailable(balance, shares);
            ICcipWithdrawManager(withdrawManager).requestShares(shares);
            // Bound the fee the (remotely mutable) manager took out of this contract's shares (IL-8603).
            uint256 balanceAfter = IERC20(vault).balanceOf(address(this));
            uint256 deducted = balance > balanceAfter ? balance - balanceAfter : 0;
            if (maxFeeShares != type(uint256).max && deducted > maxFeeShares) {
                revert RequestSharesFeeExceeded(vault, deducted, shares, maxFeeShares);
            }
            uint256 afterShares = ICcipWithdrawManager(withdrawManager).requestInfo(address(this)).shares;
            // The WithdrawManager REPLACES its stored request on every `requestShares` and takes the fee out of
            // this contract's shares, so the event reports the manager's read-back outstanding request. The
            // dispatcher keeps no copy (IL-8410): the manager bounds REDEEM_FROM_REQUEST and `balanceOf` alone
            // proves a live position.
            emit SharesRequested(vault, afterShares, deducted);
        } else if (command.action == uint8(BusinessAction.REDEEM_FROM_REQUEST)) {
            (
                address withdrawManager,
                address vault,
                uint256 shares,
                uint256 minAssetsSD,
                address receiver
            ) = CrosschainMessages.decodeRedeemFromRequestAction(command.actionData);
            if (!isTrackedVault[vault]) revert VaultNotTracked(vault);
            // The redeemed assets must land in this contract's own ledger: any other receiver is refused.
            if (receiver != address(this)) revert CrosschainErrors.ReceiverMustBeSelf(receiver);
            // Consistency check only — the vault executes the redeem against its own manager; see
            // `_requireVaultWithdrawManager`.
            _requireVaultWithdrawManager(vault, withdrawManager);
            // The request bound is enforced by the vault's WithdrawManager (`canWithdrawFromRequest`).
            uint256 beforeBalance = IERC20(_assetImm()).balanceOf(address(this));
            IPlasmaVault(vault).redeemFromRequest(shares, address(this), address(this));
            uint256 receivedSD;
            (delta, receivedSD) = _creditReceived(beforeBalance, minAssetsSD, type(uint256).max);
            emit RedeemedFromRequest(vault, shares, receivedSD);
        } else {
            revert UnsupportedAction(command.action);
        }
    }

    /// @dev Credits the MEASURED asset delta, floored: `redeem` returns an arbitrary integer (audit C-2).
    ///      `reported_` = type(uint256).max skips the reported-assets floor (REDEEM_FROM_REQUEST).
    function _creditReceived(
        uint256 beforeBalance_,
        uint256 minAssetsSD_,
        uint256 reported_
    ) private returns (int256 delta, uint256 receivedSD) {
        uint256 received = IERC20(_assetImm()).balanceOf(address(this)) - beforeBalance_;
        uint256 minAssets = _toLD(minAssetsSD_);
        if (reported_ < minAssets || received < minAssets) revert MinimumNotMet(received, minAssets);
        receivedSD = _toSDFloor(received);
        trackedIdle += receivedSD;
        delta = _toInt256(receivedSD);
    }

    function _completeCommand(Command memory command_, int256 delta_) private {
        commandStatus[command_.commandId] = CommandStatus.SUCCEEDED;
        ++nextCommandSequence;
        // Value-neutral for the version (IL-8257): the ACK carries the CURRENT `stateVersion` as evidence.
        // A command only moves value between `trackedIdle` and vault positions here; the executor keeps no NAV
        // bucket for it, so the change reaches the executor through the next attestation, not the frontier.
        _sendCommandAck(command_.commandId, command_.sequence, delta_, stateVersion, CommandResolution.SUCCEEDED);
        emit CommandSucceeded(command_.commandId, command_.sequence, delta_);
    }

    function _retryCommand(bytes32 commandId_) private {
        CommandStatus status = commandStatus[commandId_];
        // A retry for an already-resolved command is a duplicate, not an error: answering it with a
        // revert would leave an unexecutable message on the lane (mirrors the Stargate dispatcher).
        if (status == CommandStatus.SUCCEEDED || status == CommandStatus.CANCELLED) return;
        if (status != CommandStatus.FAILED) revert CommandNotFailed(commandId_);
        bytes memory stored = _storedCommands[commandId_];
        if (keccak256(stored) != commandCommitment[commandId_]) revert CommandCommitmentMismatch(commandId_);
        (CcipMsgType storedType, Command memory command, bytes memory extra) = abi.decode(
            stored,
            (CcipMsgType, Command, bytes)
        );
        if (command.sequence != nextCommandSequence) revert InvalidSequence(nextCommandSequence, command.sequence);
        _runCommand(storedType, command, extra);
    }

    /// @dev Same TTL fence as `runStoredCommand` (IL-8594). A FAILED CANCEL_COMMAND stays executable on the OffRamp
    ///      and CCIP 2.0 runs it out of order, so one outliving an executor-side `ABANDON_COMMAND` could land after
    ///      the replacement reused the sequence and consume it, silently dropping the replacement's action. Past the
    ///      deadline the cancel therefore does not touch the sequence: the command is marked CANCELLED, which doubles
    ///      as the replay guard, and the answer is an `EXPIRED` ACK, never `CANCELLED`: a CANCELLED receipt would
    ///      reach the executor's `_adoptLateReceipt` and could retire the still-PENDING replacement of an abandoned
    ///      command, whereas the executor honours `EXPIRED` only for the command still owning its slot as FAILED and
    ///      never moves its sequence mirror for it. That frees the lane without the admin when the command expired
    ///      while FAILED. If the lane already passed the command's sequence (abandoned, replacement ran) the receipt
    ///      would be useless and is not sent. It is NOT a no-op: the receipt goes through `_queueResponse`, whose
    ///      capacity checks (`ResponseQueueNeutralCapReached`, `ResponseQueueFull`) can revert the delivery; the
    ///      CANCEL then stays re-executable on the OffRamp (harmless) until the queue head is flushed or skipped.
    ///      An expired command can never run (`runStoredCommand` refuses it), so closing it loses nothing.
    function _cancelCommand(bytes32 commandId_) private {
        CommandStatus status = commandStatus[commandId_];
        if (status == CommandStatus.SUCCEEDED || status == CommandStatus.CANCELLED) return; // idempotent
        if (status != CommandStatus.FAILED) revert CommandNotFailed(commandId_);
        (, Command memory command, ) = abi.decode(_storedCommands[commandId_], (CcipMsgType, Command, bytes));
        uint256 deadline = CrosschainMessages.commandDeadline(commandId_);
        bool expired = block.timestamp > deadline;
        if (!expired && command.sequence != nextCommandSequence) {
            revert InvalidSequence(nextCommandSequence, command.sequence);
        }
        commandStatus[commandId_] = CommandStatus.CANCELLED;
        if (expired) {
            emit CancelCommandExpiredIgnored(_executorChainIdImm(), commandId_, command.sequence, uint64(deadline));
            if (command.sequence != nextCommandSequence) return; // the lane passed it: no receipt is needed
        } else {
            ++nextCommandSequence;
        }
        // The command was NOT applied, so `commandConfigEpoch` is unchanged; the receipt says so explicitly
        // rather than leaving the executor to infer it from a local flag.
        _sendCommandAck(
            commandId_,
            command.sequence,
            0,
            stateVersion,
            expired ? CommandResolution.EXPIRED : CommandResolution.CANCELLED
        );
        if (!expired) emit CommandCancelled(commandId_, command.sequence);
    }

    function _sendCommandNack(bytes32 commandId_, uint64 sequence_) private {
        _queueResponse(CcipMsgType.COMMAND_NACK, abi.encode(commandId_, sequence_), 0);
    }

    function _sendCommandAck(
        bytes32 commandId_,
        uint64 sequence_,
        int256 delta_,
        uint64 version_,
        CommandResolution resolution_
    ) private {
        _queueResponse(
            CcipMsgType.COMMAND_ACK,
            abi.encode(
                commandId_,
                sequence_,
                delta_,
                _reportedBalance(),
                version_,
                commandConfigEpoch,
                uint8(resolution_)
            ),
            0
        );
    }

    /// @notice The balance the executor attests for this dispatcher, in shared decimals.
    /// @dev Idle tracked asset, tokens queued for return and the priced tracked vault positions (see `observation`
    ///      for the per-vault pricing flags and the other attestation fields read from the same state).
    function accountedBalance() external view returns (uint256) {
        return _accountedBalance();
    }

    /// @notice Returns balance and all attestation-binding metadata from the same EVM state snapshot.
    /// @dev Attesters gate on `unpricedCount` here. Tracked vaults are priced with `VIEW_CONVERT_GAS` for
    ///      `convertToAssets` (IL-8602 review G-1), unlike the on-chain responses (`VAULT_READ_GAS`), so a
    ///      multi-market vault a response flags can still be priced here. Call it with a high gas limit: too little
    ///      gas reverts `InsufficientGasForVaultRead`, it never understates.
    function observation() external view returns (CcipObservation memory) {
        (uint256 balance, uint256 unpricedCount, uint256 unpricedCodes) = _valuation(
            TrackedVaultPricingLib.VIEW_CONVERT_GAS
        );
        return
            CcipObservation({
                accountedBalance: balance,
                trackedIdle: trackedIdle,
                queuedTokenAmount: queuedTokenAmount,
                stateVersion: stateVersion,
                commandConfigEpoch: commandConfigEpoch,
                trackedPositionSetHash: _trackedPositionSetHash(),
                unpricedCount: unpricedCount,
                unpricedCodes: unpricedCodes
            });
    }

    /// @notice Number of vaults in the tracked set (at most `MAX_TRACKED_VAULTS`).
    function trackedVaultsLength() external view returns (uint256) {
        return trackedVaults.length;
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

    /// @dev Authoritative manager check: ask the VAULT which manager it is configured with, by executing
    ///      `plasmaVaultWithdrawManager()` in the vault's storage context through `UniversalReader.read`
    ///      (public on every PlasmaVault since IL-5094). Only call on a vault already in the tracked set —
    ///      it passed the allowlist's code/asset validation, and the answer is only as honest as the vault.
    ///      A vault without `read` reverts here, which is the right outcome. In practice that means a plain
    ///      ERC-4626 on the allowlist: `read` (IL-5094) predates `PlasmaVault.redeemFromRequest`, so no
    ///      PlasmaVault has the async path without it.
    function _requireVaultWithdrawManager(address vault_, address withdrawManager_) private view {
        CrosschainVaultActionLib.requireVaultWithdrawManager(vault_, withdrawManager_);
    }

    /// @dev `replace_` gives the CCIP transport the same "the remote allowlist is exactly this set"
    ///      primitive the Stargate `UPDATE_VAULTS` has, so the same governance intent produces the same
    ///      remote state on both transports (audit M-6). Additive/removal mode is kept for incremental
    ///      changes. A vault leaving the allowlist is swept (best-effort redeem) and untracked in
    ///      the same call (IL-8784); the redeemed assets are returned in local decimals for `trackedIdle`.
    function _configureVaults(
        address[] memory vaults_,
        bool allowed_,
        bool replace_
    ) private returns (uint256 sweptAssetsLD) {
        return
            CcipDispatcherLib.configureVaults(
                isAllowedVault,
                isTrackedVault,
                _trackedVaultIndexPlusOne,
                trackedVaults,
                _assetImm(),
                vaults_,
                allowed_,
                replace_
            );
    }

    /// @dev The absolute remote balance read by off-chain attesters through `accountedBalance()`; responses to the
    ///      executor carry the same `_valuation`, with the on-chain budget, through `_reportedBalance`.
    ///      `convertToAssets` returns an arbitrary integer, so it MUST be floored — an exact conversion
    ///      reverts on the first wei of yield and, because this is on the hot path of every inbound
    ///      handler, would brick the dispatcher entirely (audit C-2).
    ///      Tokens already debited from `trackedIdle` but still sitting in an undispatched response are
    ///      counted through `queuedTokenAmount`: they are physically here and still remote-owned, so
    ///      omitting them would make attesters understate remote NAV (audit M-8). Responses to the executor
    ///      subtract that term again (see `_reportedBalance`, IL-8768).
    ///      A tracked vault whose reads fail is skipped, never fatal (IL-8602): the balance is then understated and
    ///      the failure is surfaced through `_reportedBalance`'s event and `observation().unpricedCount`.
    ///      Priced with the view budget for `convertToAssets` (`VIEW_CONVERT_GAS`, IL-8602 review G-1): only the
    ///      external views read it.
    function _accountedBalance() private view returns (uint256 balance) {
        (balance, , ) = _valuation(TrackedVaultPricingLib.VIEW_CONVERT_GAS);
    }

    function _valuation(
        uint256 convertGas_
    ) private view returns (uint256 balance, uint256 unpricedCount, uint256 unpricedCodes) {
        balance = trackedIdle + queuedTokenAmount;
        uint256 len = trackedVaults.length;
        for (uint256 i; i < len; ++i) {
            (uint256 assets, uint8 reason) = TrackedVaultPricingLib.price(
                trackedVaults[i],
                address(this),
                _assetImm(),
                convertGas_
            );
            if (reason == TrackedVaultPricingLib.PRICED && assets <= type(uint128).max) {
                balance += _toSDFloor(assets);
            } else {
                if (reason == TrackedVaultPricingLib.PRICED) reason = TrackedVaultPricingLib.UNPRICED_CONVERT_TO_ASSETS;
                ++unpricedCount;
                unpricedCodes |= uint256(reason) << (i * 2);
            }
        }
    }

    /// @dev `_accountedBalance` for a response about to be queued: also emits `TrackedVaultUnpriced` per failed vault.
    ///      Unlike `_accountedBalance` it EXCLUDES `queuedTokenAmount` (IL-8768): it reports the balance as it will be
    ///      once every token response queued ahead of it has been applied, because the executor applies token
    ///      responses strictly by version (a value-neutral BALANCE_REPORT / COMMAND_ACK may land before them, but its
    ///      figure is still the one valid after they are applied). Counting those tokens again would leave a phantom
    ///      residual anchor once a later response empties `settled`.
    function _reportedBalance() private returns (uint256 balance) {
        uint256 unpricedCount;
        uint256 unpricedCodes;
        // On-chain budget: the figure is evidence, and a gas-burning vault must not make every delivery heavy. A
        // multi-market vault the view prices can be flagged here; attesters gate on `observation()` (IL-8602 G-1).
        (balance, unpricedCount, unpricedCodes) = _valuation(TrackedVaultPricingLib.VAULT_READ_GAS);
        // IL-8768: queued token responses are applied first; observation()/accountedBalance() keep them (audit M-8)
        balance -= queuedTokenAmount; // _valuation >= trackedIdle + queuedTokenAmount: no underflow
        if (unpricedCount == 0) return balance;
        uint256 len = trackedVaults.length;
        for (uint256 i; i < len; ++i) {
            uint8 reason = uint8((unpricedCodes >> (i * 2)) & 3);
            if (reason != 0) emit TrackedVaultUnpriced(trackedVaults[i], reason);
        }
    }

    // ============================================================
    // Tracked-position set views (the timelocked force-untrack was removed: tracked == allowlisted, IL-8784)
    // ============================================================

    /// @notice Canonical tracked-position-set commitment bound by balance attestations.
    /// @dev Mirrors `StargateCrosschainDispatcher._trackedPositionSetHash` so a CCIP approver has the same
    ///      on-chain handle for "the position set I verified is the one that was observed" (audit M-1).
    function trackedPositionSetHash() external view returns (bytes32) {
        return _trackedPositionSetHash();
    }

    function _trackedPositionSetHash() private view returns (bytes32) {
        return keccak256(abi.encode(address(this), block.chainid, trackedVaults));
    }

    /// @dev A `BALANCE_REPORT` carries no version bump (IL-8257) and only the latest one matters, so while one is
    ///      still queued a new request rewrites its payload in place instead of appending (IL-8583). The id, the
    ///      FIFO position and `queuedTokenAmount` (0 for a report) are untouched, so ids stay strictly increasing
    ///      and head/tail are not modified. The refreshed report may now sit ahead of a later `TRANSFER_SETTLED` /
    ///      `RETURN_TRANSFER`; that is the same overtaking the executor already tolerates for value-neutral
    ///      responses (`CcipValueNeutralVersionTest`).
    function _sendBalanceMessage(uint64 stateVersion_) private {
        bytes memory payload = abi.encode(_reportedBalance(), stateVersion_);
        uint64 queuedId = _queuedBalanceReportId;
        if (queuedId != 0 && _queuedResponses[queuedId].data.length != 0) {
            _queuedResponses[queuedId].data = CcipMessages.encode(CcipMsgType.BALANCE_REPORT, payload);
            emit ResponseCoalesced(queuedId);
            return;
        }
        _queuedBalanceReportId = _queueResponse(CcipMsgType.BALANCE_REPORT, payload, 0);
    }

    /// @notice Permissionless response-queue recovery. The first unsent response is
    ///         retried after its fee budget or receiver failure has been repaired.
    function flushResponse() external nonReentrant returns (bytes32 messageId) {
        uint64 head = responseQueueHead;
        if (head == 0) revert NoQueuedResponse();
        messageId = _dispatchResponse(head);
    }

    /// @notice Permissionless bounded drain: dispatches up to `maxCount_` responses from the queue head, in FIFO
    ///         order, and returns how many were sent (IL-8583).
    /// @dev The first dispatch behaves exactly like `flushResponse()` (it reverts with the send failure, so a
    ///      caller learns why the head is stuck). A later failure only stops the loop: the responses already sent
    ///      stay sent. Reverts `NoQueuedResponse` on an empty queue. `maxCount_ == 0` sends nothing.
    function flushResponse(uint256 maxCount_) external nonReentrant returns (uint256 flushed) {
        uint64 head = responseQueueHead;
        if (head == 0) revert NoQueuedResponse();
        while (flushed < maxCount_ && head != 0) {
            if (flushed == 0) {
                _dispatchResponse(head);
            } else {
                (bool ok, ) = _tryDispatchHead(head);
                if (!ok) break;
            }
            ++flushed;
            head = responseQueueHead;
        }
    }

    /// @notice Sends the queued response `responseId_` to the executor.
    /// @dev Self-call only (`OnlySelf`): it is reached through `this` from `flushResponse(maxCount_)` for every
    ///      entry after the first, so a failed send stops the drain instead of reverting it, and from
    ///      `_tryDispatchHead` for a response queued at the head (`_queueResponse`, and the RETURN_TRANSFER path). The queue is strictly
    ///      FIFO, so `responseId_` has to be the head of the queue.
    function dispatchResponseSelf(uint64 responseId_) external returns (bytes32 messageId) {
        if (msg.sender != address(this)) revert OnlySelf();
        messageId = _dispatchResponse(responseId_);
    }

    /// @notice Schedule a timelocked drop of a response that can never be delivered.
    /// @dev Last-resort valve for the response queue: the queue is strictly FIFO, so one permanently
    ///      undeliverable head would otherwise block every later response forever (audit C-1). The known
    ///      causes are fixed at the source; this exists so an unknown one cannot strand capital. Dropping a
    ///      token-bearing response returns its tokens to `trackedIdle` — they never left, and for a return
    ///      response the executor still counts them in `settledRemoteBalance` (whose only subtraction is on
    ///      a delivered `RETURN_TRANSFER` receipt, `CcipExecutorAttestationLib.applyReturnDebit`) — so
    ///      `accountedBalance()` / `observation()` and the rescue floor (`trackedIdle + queuedTokenAmount`) are unchanged
    ///      (IL-8064); the balance carried by later responses rises by the dropped amount, because since IL-8768 it
    ///      excludes only what is still queued (the executor still counts those tokens in `settledRemoteBalance`). The executor's recall record for that
    ///      response stays open: cancel it there (`cancelPendingReturn`, MANAGER-gated via
    ///      `CcipCrosschainCommandFuse`'s `CANCEL_RETURN`, or the permissionless `cancelStalePendingReturn`
    ///      once stale) and re-issue the recall. The cancelled recall's staleness clock (IL-8590) is cleared
    ///      by a late return, a `RETURN_REJECTED`, `FORCE_SET_SETTLED` or the `ADVANCE_FRONTIER` that repairs
    ///      the skipped version (which is the usual exit here); the two rescues clear it only past the reset
    ///      guard's `refusedUntil` (before it `FORCE_SET_SETTLED` reverts and `ADVANCE_FRONTIER` keeps the clock).
    ///      Full rescue delay and guardian veto apply; the drop itself is irreversible. `stateVersion` is not
    ///      touched: dropping a value-neutral response (`BALANCE_REPORT`, `COMMAND_ACK`, ...) is harmless to
    ///      the frontier, but dropping a `TRANSFER_SETTLED` or `RETURN_TRANSFER` response leaves a version the
    ///      executor never sees, so the frontier then stays one behind for good and only the timelocked
    ///      `ADVANCE_FRONTIER` rescue repairs it (IL-8257).
    function scheduleSkipStuckResponse(uint64 responseId_) external onlyRescueAdmin returns (uint256 rescueId) {
        _requireHead(responseId_);
        return _scheduleForceResolve(_skipCommitment(responseId_));
    }

    /// @notice Drop a permanently undeliverable head-of-queue response after the rescue delay.
    function executeSkipStuckResponse(uint256 rescueId_, uint64 responseId_) external onlyRescueAdmin {
        _consumeForceResolve(rescueId_, _skipCommitment(responseId_));
        _requireHead(responseId_);
        _dropHeadResponse(responseId_);
    }

    function _skipCommitment(uint64 responseId_) private pure returns (bytes32) {
        return keccak256(abi.encode("CCIP_SKIP_RESPONSE", responseId_));
    }

    /// @dev Drops the undispatched queue head, shared by the skip rescue and the capacity unwind.
    function _dropHeadResponse(uint64 responseId_) private {
        uint256 amount = _queuedResponses[responseId_].amountLD;
        if (amount != 0) {
            // Nothing was sent: the tokens are still here (a dispatch deletes the record before
            // `_sendCcip`, so an undispatched record always means undelivered tokens). Move the value back
            // from the queue bucket to idle so `_accountedBalance()` and the rescue floor are unchanged and
            // a re-issued recall can bring it home through the normal path (IL-8064).
            uint256 amountSD = _toSDFloor(amount);
            queuedTokenAmount -= amountSD;
            trackedIdle += amountSD;
        }
        delete _queuedResponses[responseId_];
        responseQueueHead = responseId_ == responseQueueTail ? 0 : responseId_ + 1;
        emit ResponseSkipped(responseId_, amount);
    }

    /// @notice Schedule a timelocked transfer of `amountSD_` tracked idle ASSET (shared decimals) to the
    ///         rescue admin.
    /// @dev Last-resort exit for idle value when the lane can no longer carry a recall home (lane cursed
    ///      or retired, router or token pool paused, executor unable to send). Every other `trackedIdle`
    ///      debit needs an authenticated inbound message, and a generic rescue only reaches surplus above
    ///      the floor (`_afterRescueExecuted`), so without this the value would stay here with no Fusion
    ///      role able to move it (IL-8251). Full rescue delay and guardian veto apply. Value still sitting
    ///      in an undispatched response is not idle: drop that response first with
    ///      `scheduleSkipStuckResponse`, which re-credits it to `trackedIdle`. Pays only the immutable
    ///      `ADMIN()` at execution: if the ASSET issuer blocklists `ADMIN` on this chain, a
    ///      recipient-checking token (e.g. USDC) makes `executeAdminRecall` revert and tracked idle has no on-chain
    ///      exit until the lane recovers or the block is lifted, while a sender-only token (USDT, USDT0) lets it
    ///      succeed and freezes the tokens at `ADMIN` (IL-8807). Check the issuer's blocklist for `ADMIN` before
    ///      scheduling.
    function scheduleAdminRecall(uint256 amountSD_) external onlyRescueAdmin returns (uint256 rescueId) {
        return _scheduleForceResolve(_adminRecallCommitment(amountSD_));
    }

    /// @notice Transfer up to the scheduled amount of tracked idle ASSET to the rescue admin after the
    ///         rescue delay.
    /// @dev Clamped to the current `trackedIdle`, which may have shrunk during the delay. The debit lowers
    ///      `accountedBalance()` and the rescue floor by the same amount; no message is sent, because the
    ///      lane is presumed unusable. `stateVersion` is deliberately left unchanged (it counts only the
    ///      value-moving responses `TRANSFER_SETTLED` / `RETURN_TRANSFER`, IL-8257, and no response ever
    ///      carries a version for this transition): a bump would make the next delivered response gap the
    ///      executor's frontier and block the chain. The
    ///      executor still counts the value in `settledRemoteBalance` until the operator lowers it with the
    ///      timelocked `FORCE_SET_SETTLED` chain rescue; the recalled tokens return to the vault manually
    ///      from the admin. Observable through `ForceResolveConsumed` and the asset's `Transfer`. Pays only the
    ///      immutable `ADMIN()`; if the ASSET issuer blocklists `ADMIN` on this chain, a recipient-checking
    ///      token (e.g. USDC) reverts and tracked idle has no on-chain exit until the lane recovers or the block is
    ///      lifted, while a sender-only token (USDT, USDT0) succeeds and freezes the tokens at `ADMIN` (IL-8807).
    function executeAdminRecall(uint256 rescueId_, uint256 amountSD_) external onlyRescueAdmin {
        _consumeForceResolve(rescueId_, _adminRecallCommitment(amountSD_));
        uint256 amount = amountSD_ > trackedIdle ? trackedIdle : amountSD_;
        trackedIdle -= amount;
        CrosschainVaultActionLib.transferAssetToAdmin(_toLD(amount));
    }

    /// @dev A `bytes32` domain tag rather than a string literal: identical separation, fewer bytes.
    function _adminRecallCommitment(uint256 amountSD_) private pure returns (bytes32) {
        return keccak256(abi.encode(bytes32("ADMIN_RECALL_IDLE"), amountSD_));
    }

    /// @notice The queued response `responseId_`: encoded message, token (zero when message-only) and the token
    ///         amount in LOCAL ASSET decimals (`amountLD`). `queuedTokenAmount` / `trackedIdle` are SHARED decimals.
    function queuedResponse(
        uint64 responseId_
    ) external view returns (bytes memory data, address token, uint256 amountLD) {
        QueuedResponse storage response = _queuedResponses[responseId_];
        amountLD = response.amountLD;
        return (response.data, amountLD == 0 ? address(0) : _assetImm(), amountLD);
    }

    /// @dev Appends a response and attempts delivery when it lands at the head. It reverts only when the queue
    ///      has no slot for this response type (`_enqueueResponse`); an undeliverable CCIP send never reverts it.
    function _queueResponse(
        CcipMsgType messageType_,
        bytes memory payload_,
        uint256 amount_
    ) private returns (uint64 responseId) {
        responseId = _enqueueResponse(messageType_, payload_, amount_);
        // The application transition must not revert merely because CCIP delivery
        // cannot currently be purchased or executed. FIFO is preserved because
        // only the head is attempted here and by flushResponse().
        if (responseQueueHead == responseId) _tryDispatchHead(responseId);
    }

    /// @dev Attempts the head dispatch; returns the caught revert bytes instead of bubbling them.
    function _tryDispatchHead(uint64 responseId_) private returns (bool ok, bytes memory reason) {
        try this.dispatchResponseSelf(responseId_) {
            ok = true;
        } catch (bytes memory caught) {
            reason = caught;
        }
    }

    /// @dev Stores the response and credits `queuedTokenAmount`; the caller decides whether to attempt delivery.
    ///      Capacity (IL-8583): `MAX_QUEUED_RESPONSES` live responses is the hard cap (`ResponseQueueFull`). The
    ///      value-neutral types `BALANCE_REPORT` and `COMMAND_ACK` stop `RESERVED_FOR_VALUE_MOVING` slots earlier
    ///      (`ResponseQueueNeutralCapReached`), so `TRANSFER_SETTLED`, `RETURN_TRANSFER`, `RETURN_REJECTED` and
    ///      `COMMAND_NACK` - whose revert would strand tokens, a recall or the FAILED outcome of a command - still
    ///      get a slot while a stalled head keeps the neutral traffic out. The reserved band is only
    ///      `RESERVED_FOR_VALUE_MOVING` deep: past the soft cap just that many more of those responses fit before
    ///      `ResponseQueueFull`, so a stalled head should be repaired or skipped before then.
    function _enqueueResponse(
        CcipMsgType messageType_,
        bytes memory payload_,
        uint256 amount_
    ) private returns (uint64 responseId) {
        uint64 head = responseQueueHead;
        uint64 tail = responseQueueTail;
        if (head != 0) {
            uint256 live = uint256(tail - head) + 1;
            if (live >= MAX_QUEUED_RESPONSES) revert ResponseQueueFull(MAX_QUEUED_RESPONSES);
            if (
                (messageType_ == CcipMsgType.BALANCE_REPORT || messageType_ == CcipMsgType.COMMAND_ACK) &&
                live >= MAX_QUEUED_RESPONSES - RESERVED_FOR_VALUE_MOVING
            ) revert ResponseQueueNeutralCapReached(live, MAX_QUEUED_RESPONSES - RESERVED_FOR_VALUE_MOVING);
        }
        responseId = ++responseQueueTail;
        _queuedResponses[responseId] = QueuedResponse({
            data: CcipMessages.encode(messageType_, payload_),
            amountLD: amount_
        });
        if (head == 0) responseQueueHead = responseId;
        if (amount_ != 0) queuedTokenAmount += _toSDFloor(amount_);
        emit ResponseQueued(responseId, messageType_, amount_);
    }

    function _dispatchResponse(uint64 responseId_) private returns (bytes32 messageId) {
        _requireHead(responseId_);
        QueuedResponse storage stored = _queuedResponses[responseId_];
        bytes memory data = stored.data;
        uint256 amount = stored.amountLD;
        CcipRouteConfig memory route = _ccipRoutes[_executorChainIdImm()];
        if (amount != 0) queuedTokenAmount -= _toSDFloor(amount);
        delete _queuedResponses[responseId_];
        responseQueueHead = responseId_ == responseQueueTail ? 0 : responseId_ + 1;
        (messageId, ) = _sendCcip(
            _executorChainIdImm(),
            data,
            amount == 0 ? address(0) : _assetImm(),
            amount,
            route.maxFee,
            route.feeToken,
            amount != 0 ? route.tokenGasLimit : route.messageGasLimit
        );
        emit ResponseDispatched(responseId_, messageId);
    }

    function _requireHead(uint64 responseId_) private view {
        if (responseId_ == 0 || responseId_ != responseQueueHead) revert NoQueuedResponse();
    }

    /// @dev Reads `ASSET` through one shared JUMP target instead of inlining the immutable at every use (EIP-170).
    function _assetImm() private view returns (address) {
        return ASSET;
    }

    /// @dev Reads `EXECUTOR_CHAIN_ID` through one shared JUMP target instead of inlining the immutable (EIP-170).
    function _executorChainIdImm() private view returns (uint256) {
        return EXECUTOR_CHAIN_ID;
    }

    function _toInt256(uint256 amount_) private pure returns (int256) {
        if (amount_ > uint256(type(int256).max)) revert AccountingDeltaOverflow(amount_);
        return int256(amount_);
    }

    function _beforeRescueExecuted() internal view override returns (uint256) {
        return IERC20(_assetImm()).balanceOf(address(this));
    }

    function _afterRescueExecuted(uint256 balanceBefore_) internal override {
        uint256 balance = IERC20(_assetImm()).balanceOf(address(this));
        uint256 required = _toLD(trackedIdle + queuedTokenAmount);
        if (balanceBefore_ < required) required = balanceBefore_;
        if (balance < required) revert InsufficientTrackedIdle(balance, required);
    }

    /// @inheritdoc CcipAppBase
    /// @dev Adds `nonReentrant` to the base implementation, so no inbound message handler can be re-entered.
    function ccipReceive(CcipClient.Any2EVMMessage calldata message_) public override nonReentrant {
        super.ccipReceive(message_);
    }

    /// @dev Truncating: for measured / externally supplied amounts. Never reverts.
    function _toSDFloor(uint256 amountLD_) private view returns (uint256) {
        return amountLD_ / DECIMAL_CONVERSION_RATE;
    }

    /// @dev Rounding up: for debits against `trackedIdle`. Never reverts.
    function _toSDCeil(uint256 amountLD_) private view returns (uint256) {
        return CcipDecimalsLib.toSDCeil(amountLD_, DECIMAL_CONVERSION_RATE);
    }

    function _toLD(uint256 amountSD_) private view returns (uint256) {
        return amountSD_ * DECIMAL_CONVERSION_RATE;
    }
}
/// @title CCIP-local reason accompanying a `RETURN_REJECTED`
/// @dev Values 0-2 (NONE, NO_TRACKED_IDLE, BELOW_MINIMUM) mirror the shared `ReturnRejectReason` in
///      `CrosschainConstants.sol`; every value is encoded to the wire as a `uint8`. 3 (INVALID_BOUND),
///      4 (ABOVE_POOL_CAPACITY) and 5 (EXPIRED) are CCIP-only. The shared enum's 3 is Stargate's
///      ABOVE_PATH_CREDIT, so the two diverge from 3.
enum CcipReturnRejectReason {
    NONE,
    NO_TRACKED_IDLE,
    BELOW_MINIMUM,
    INVALID_BOUND,
    /// @dev The recall exceeds the local token pool's outbound rate-limit CAPACITY (IL-8553): it could never
    ///      be sent until the pool admin raises the capacity, so it is rejected before any value moves.
    ABOVE_POOL_CAPACITY,
    /// @dev The request was executed after its `deadline` (IL-8590): the executor's recall window had already
    ///      elapsed, so no value moved. The keeper may simply request again.
    EXPIRED
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "../../IFuseCommon.sol";
import {ICrosschainExecutor} from "../../../crosschain/interfaces/ICrosschainExecutor.sol";
import {Command, CrosschainMessages} from "../../../crosschain/lib/CrosschainMessages.sol";
import {BusinessAction} from "../../../crosschain/lib/CrosschainConstants.sol";
import {CrosschainSubstrateLib} from "../lib/CrosschainSubstrateLib.sol";

/// @notice Intrinsic marker of the Stargate transport: `StargateOAppBase` exposes the local Stargate
///         pool as a public immutable. A CCIP executor has no such getter, so a successful call
///         returning a non-zero pool proves the executor speaks this transport (audit M-5).
interface IStargateTransportProbe {
    function STARGATE_POOL() external view returns (address);
}

interface IStargateRetryWithBudget {
    /// @dev IL-8625: retry a FAILED command with a raised gas budget (the dispatcher keeps `max(stored, raised)`).
    function retryCommandWithBudget(uint256 dstChainId_, uint64 minExecutionGas_) external;
}

interface IStargateChainBlocked {
    function chainBlocked(uint256 chainId_) external view returns (bool);
}

interface IStargateActiveCommandAction {
    /// @dev Business action of the executor's active command on the chain (0 if none / config update).
    function activeCommandAction(uint256 chainId_) external view returns (uint8);
    /// @dev Target vault of the executor's active command on the chain when it is a DEPOSIT (0 otherwise).
    function activeCommandTarget(uint256 chainId_) external view returns (address);
}

import {CrosschainRecoveryLib} from "../lib/CrosschainRecoveryLib.sol";

/// @notice Manager-operation discriminator for `StargateCrosschainCommandFuse.enter`.
/// @dev The executor's `MANAGER` is the PlasmaVault (immutable), so every manager-only executor operation
///      — chain registration, dispatcher lifecycle, allowlist updates and business/recall commands — is
///      reachable ONLY through this fuse (plan §5.1). This enum selects which one to forward.
enum StargateCrosschainCommandType {
    UNDEFINED, // 0 - invalid
    REGISTER_CHAIN, // 1 - executor.registerChain(chainId, eid, enforcedOptions)
    CREATE_DISPATCHER, // 2 - executor.createDispatcher(chainId, plasmaVaults)
    UPDATE_PLASMA_VAULTS, // 3 - executor.updatePlasmaVaults(chainId, plasmaVaults)
    SEND_COMMAND, // 4 - executor.sendCommandToDispatcher(chainId, command)
    CANCEL_DISPATCHER_REQUEST, // 5 - executor.cancelDispatcherRequest(requestId)
    RETRY_COMMAND, // 6 - executor.retryCommand(chainId), or retryCommandWithBudget when command.minExecutionGas != 0
    CANCEL_COMMAND // 7 - executor.cancelCommand(chainId)
}

/// @notice Tagged-union enter data for the crosschain command fuse. Only the fields relevant to
///         `commandType` are read; the rest are ignored.
/// @param commandType Which manager operation to forward to the executor.
/// @param executor The StargateCrosschainExecutor to drive (must be a granted EXECUTOR substrate).
/// @param chainId Target/destination EVM chainId (REGISTER_CHAIN registers it; the others address a dispatcher on it;
///        ignored by CANCEL_DISPATCHER_REQUEST, which emits 0).
/// @param eid LayerZero endpoint id for the chain being registered (REGISTER_CHAIN only).
/// @param enforcedOptions Enforced LayerZero options for the registered path (REGISTER_CHAIN only).
/// @param plasmaVaults Remote PlasmaVault allowlist (CREATE_DISPATCHER / UPDATE_PLASMA_VAULTS); every entry
///        must be granted as a REMOTE_VAULT substrate for `chainId`.
/// @param requestId Deployment request id to cancel (CANCEL_DISPATCHER_REQUEST only).
/// @param command Business command envelope forwarded to the dispatcher (SEND_COMMAND only). DEPOSIT `amount`
///        and REDEEM / REDEEM_FROM_REQUEST `minAssets` are in SHARED decimals (the dispatcher applies `_toLD`
///        to `minAssets` before comparing with the measured `assetsDelta`, IL-8609); all forwarded verbatim by
///        `StargateCrosschainExecutor.sendCommandToDispatcher`. The CCIP command fuse differs: it takes
///        LOCAL ASSET decimals and the CCIP executor normalises them. REQUEST_SHARES carries `shares` and a
///        `maxFeeShares` fee ceiling, both in share units and never converted (`type(uint256).max` = no ceiling;
///        IL-8603). `command.minExecutionGas` (IL-8625): SEND_COMMAND, 0 or a value not above the lane's budget
///        keeps that budget, a higher one (at most `MAX_COMMAND_EXECUTION_GAS`, 14M) becomes the budget and the
///        executor funds it with an extra `lzReceive` option; RETRY_COMMAND, 0 = keep the stored budget, otherwise
///        a raised budget (never lower).
struct StargateCrosschainCommandFuseEnterData {
    StargateCrosschainCommandType commandType;
    address executor;
    uint256 chainId;
    uint32 eid;
    bytes enforcedOptions;
    address[] plasmaVaults;
    uint256 requestId;
    Command command;
}

/// @title StargateCrosschainCommandFuse
/// @notice Stateless fuse (delegatecall from PlasmaVault) exposing every manager-only StargateCrosschainExecutor
///         operation. Because the executor's MANAGER is the immutable PlasmaVault, these operations are
///         unreachable except through this fuse.
/// @dev Runs in the PlasmaVault storage context. MUST NOT declare storage variables; only `immutable`.
///      A fresh DEPOSIT (`SEND_COMMAND`) or an allowlist-adding `UPDATE_PLASMA_VAULTS` (non-empty list) reverts
///      `CrosschainCommandFuseChainBlocked` while the executor has circuit-broken the destination chain (IL-8580);
///      REDEEM / REQUEST_SHARES / REDEEM_FROM_REQUEST and CANCEL_COMMAND stay open for repair;
///      an empty list (pure removal) stays allowed. `RETRY_COMMAND` reads the stored command's action from the
///      executor (`activeCommandAction`, IL-8600) and is gated like a fresh send of that action. A retried DEPOSIT
///      is refused on a blocked chain, re-checks its target vault against the REMOTE_VAULT substrates
///      (`activeCommandTarget`: the substrate may have been revoked since the first send) and takes the new
///      exposure marker and the live `getBalance()` NAV read that reverts when fail-closed. A retried REDEEM /
///      REQUEST_SHARES / REDEEM_FROM_REQUEST stays a recovery. A retried UPDATE_PLASMA_VAULTS is not
///      recovery-marked, so like a fresh one it is unavailable while NAV is fail-closed, and it is refused on a
///      blocked chain whatever its list, because the executor stores only its commitment. On a blocked chain
///      `CANCEL_COMMAND` and a fresh empty list stay available; while NAV is fail-closed only `CANCEL_COMMAND` does.
///      The supply path on a blocked chain is not checked here: it is stopped by the NAV fail-closed revert in
///      `balanceByChain` / `computeNavSD` at the end of the vault transaction, not by an explicit executor check.
///      Variant dispatch is modeled on `RWAOperationFuse` (single typed entry point, internal dispatch).
///      UPDATE_PLASMA_VAULTS removal warning (IL-8784, D-060 / D-065): redeem or recall the position to zero BEFORE removing
///      a vault. A removed vault is swept best effort and always untracked, so a failed sweep drops the residual shares
///      out of NAV until the vault is allowlisted again; alert on the dispatcher's `TrackedVaultSweepResidual` event.
///      On tight lanes send ONE removal per UPDATE_PLASMA_VAULTS and adds in a separate command.
/// @author IPOR Labs
contract StargateCrosschainCommandFuse is IFuseCommon {
    /// @notice Emitted after a manager operation is forwarded to the executor.
    /// @param version The address of this fuse contract version.
    /// @param executor The StargateCrosschainExecutor driven.
    /// @param commandType The forwarded operation discriminator (`StargateCrosschainCommandType`).
    /// @param chainId The target/destination chainId of the operation (0 for CANCEL_DISPATCHER_REQUEST).
    event CrosschainCommandFuseEnter(address version, address executor, uint8 commandType, uint256 chainId);

    /// @notice Thrown when the executor's immutable MANAGER is not this PlasmaVault.
    error CrosschainCommandFuseExecutorManagerMismatch(address executor, address manager);

    /// @notice Thrown when the granted executor does not speak the Stargate/LayerZero transport.
    error CrosschainCommandFuseWrongTransport(address executor);

    /// @notice Thrown when `commandType` is UNDEFINED or otherwise unrecognized.
    error CrosschainCommandFuseUnsupportedCommandType(uint8 commandType);

    /// @notice Thrown when a fresh DEPOSIT or an allowlist-adding UPDATE_PLASMA_VAULTS, or a retry of a DEPOSIT or of
    ///         any UPDATE_PLASMA_VAULTS, targets a blocked chain.
    error CrosschainCommandFuseChainBlocked(address executor, uint256 chainId);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Forward a single manager operation to the executor, selected by `data_.commandType`.
    /// @param data_ The tagged-union enter data.
    function enter(StargateCrosschainCommandFuseEnterData memory data_) external {
        _validateExecutor(data_.executor);

        ICrosschainExecutor executor = ICrosschainExecutor(data_.executor);
        StargateCrosschainCommandType commandType = data_.commandType;

        if (commandType == StargateCrosschainCommandType.REGISTER_CHAIN) {
            executor.registerChain(data_.chainId, data_.eid, data_.enforcedOptions);
        } else if (commandType == StargateCrosschainCommandType.CREATE_DISPATCHER) {
            CrosschainSubstrateLib.validateRemoteVaultsGranted(MARKET_ID, data_.chainId, data_.plasmaVaults);
            executor.createDispatcher(data_.chainId, data_.plasmaVaults);
        } else if (commandType == StargateCrosschainCommandType.UPDATE_PLASMA_VAULTS) {
            if (data_.plasmaVaults.length != 0) _requireChainNotBlocked(data_.executor, data_.chainId);
            CrosschainSubstrateLib.validateRemoteVaultsGranted(MARKET_ID, data_.chainId, data_.plasmaVaults);
            executor.updatePlasmaVaults(data_.chainId, data_.plasmaVaults);
        } else if (commandType == StargateCrosschainCommandType.SEND_COMMAND) {
            if (data_.command.action == uint8(BusinessAction.DEPOSIT)) {
                _requireChainNotBlocked(data_.executor, data_.chainId);
            }
            _validateCommandTargetVault(data_.chainId, data_.command);
            _gateOrMarkBusinessAction(executor, data_.command.action);
            executor.sendCommandToDispatcher(data_.chainId, data_.command);
        } else if (commandType == StargateCrosschainCommandType.CANCEL_DISPATCHER_REQUEST) {
            // IL-8612: cancelling a pending deployment request moves no value, so it is recovery-marked and stays
            // usable while live NAV is fail-closed. Config commands above remain blocked.
            CrosschainRecoveryLib.markRecovery(MARKET_ID, data_.executor);
            executor.cancelDispatcherRequest(data_.requestId);
        } else if (commandType == StargateCrosschainCommandType.RETRY_COMMAND) {
            // IL-8600: a retry replays the stored command, so it is gated like a fresh send of the same action.
            uint8 storedAction = IStargateActiveCommandAction(data_.executor).activeCommandAction(data_.chainId);
            // A config update (action 0) may add vaults and the executor stores only its commitment, so any retried
            // config update is refused on a blocked chain, as a fresh DEPOSIT or a non-empty list would be.
            if (storedAction == uint8(BusinessAction.DEPOSIT) || storedAction == 0) {
                _requireChainNotBlocked(data_.executor, data_.chainId);
            }
            // The DEPOSIT target was checked at the first send only; its substrate may have been revoked since.
            if (storedAction == uint8(BusinessAction.DEPOSIT)) {
                CrosschainSubstrateLib.validateRemoteVaultGranted(
                    MARKET_ID,
                    data_.chainId,
                    IStargateActiveCommandAction(data_.executor).activeCommandTarget(data_.chainId)
                );
            }
            _gateOrMarkBusinessAction(executor, storedAction);
            // IL-8625: a non-zero `command.minExecutionGas` raises the stored command's gas budget, kept for later
            // retries too (a retry can only raise; the executor adds the extra `lzReceive` gas it needs); zero keeps
            // the stored one.
            if (data_.command.minExecutionGas != 0) {
                IStargateRetryWithBudget(data_.executor).retryCommandWithBudget(
                    data_.chainId,
                    data_.command.minExecutionGas
                );
            } else {
                executor.retryCommand(data_.chainId);
            }
        } else if (commandType == StargateCrosschainCommandType.CANCEL_COMMAND) {
            CrosschainRecoveryLib.markRecovery(MARKET_ID, data_.executor);
            executor.cancelCommand(data_.chainId);
        } else {
            revert CrosschainCommandFuseUnsupportedCommandType(uint8(commandType));
        }

        // CANCEL_DISPATCHER_REQUEST never reads `chainId`, so normalise it to 0 as documented on the event.
        uint256 emittedChainId = commandType == StargateCrosschainCommandType.CANCEL_DISPATCHER_REQUEST
            ? 0
            : data_.chainId;
        emit CrosschainCommandFuseEnter(VERSION, data_.executor, uint8(commandType), emittedChainId);
    }

    function _requireChainNotBlocked(address executor_, uint256 chainId_) private view {
        if (IStargateChainBlocked(executor_).chainBlocked(chainId_)) {
            revert CrosschainCommandFuseChainBlocked(executor_, chainId_);
        }
    }

    function _gateOrMarkBusinessAction(ICrosschainExecutor executor_, uint8 action_) private {
        if (action_ == uint8(BusinessAction.DEPOSIT)) {
            CrosschainRecoveryLib.markNewExposure();
            executor_.getBalance();
        } else if (
            action_ == uint8(BusinessAction.REDEEM) ||
            action_ == uint8(BusinessAction.REQUEST_SHARES) ||
            action_ == uint8(BusinessAction.REDEEM_FROM_REQUEST)
        ) {
            CrosschainRecoveryLib.markRecovery(MARKET_ID, address(executor_));
        }
    }

    /// @dev Source-side remote-vault gate for SEND_COMMAND: the PlasmaVault targeted by the business
    ///      action must be granted as a REMOTE_VAULT substrate for the destination `chainId_`. Actions
    ///      without a known vault target (NONE / unknown) are left to the executor/dispatcher validation.
    function _validateCommandTargetVault(uint256 chainId_, Command memory command_) internal view {
        uint8 action = command_.action;
        address targetVault;
        if (action == uint8(BusinessAction.DEPOSIT)) {
            (targetVault, , ) = CrosschainMessages.decodeDepositAction(command_.actionData);
        } else if (action == uint8(BusinessAction.REDEEM)) {
            (targetVault, , ) = CrosschainMessages.decodeRedeemAction(command_.actionData);
        } else if (action == uint8(BusinessAction.REQUEST_SHARES)) {
            (, targetVault, , ) = CrosschainMessages.decodeRequestSharesAction(command_.actionData);
        } else if (action == uint8(BusinessAction.REDEEM_FROM_REQUEST)) {
            (, targetVault, , , ) = CrosschainMessages.decodeRedeemFromRequestAction(command_.actionData);
        } else {
            return;
        }
        CrosschainSubstrateLib.validateRemoteVaultGranted(MARKET_ID, chainId_, targetVault);
    }

    /// @dev Substrate gate + chain-consistency check: the executor must be granted and its immutable
    ///      MANAGER must be this PlasmaVault (guards against driving a rogue executor, risk #9).
    ///      Deliberately does NOT check the executor's underlying asset against the vault's — command
    ///      operations move no vault-side assets; the supply fuse binds the bridged asset to the executor's
    ///      `ASSET()`, and the claim/balance fuses measure and price each executor in its own `ASSET()`.
    function _validateExecutor(address executor_) internal view {
        CrosschainSubstrateLib.validateExecutorGranted(MARKET_ID, executor_);

        address manager = ICrosschainExecutor(executor_).MANAGER();
        if (manager != address(this)) {
            revert CrosschainCommandFuseExecutorManagerMismatch(executor_, manager);
        }
        // Symmetric with the CCIP fuses, which assert `transportKind() == CHAINLINK_CCIP`: refuse a
        // cross-wired executor explicitly instead of relying on an incidental ABI selector mismatch
        // (audit M-5). Probed through `STARGATE_POOL()` rather than a self-declared transport label —
        // the pool is an intrinsic immutable of the Stargate transport base that no CCIP executor has,
        // and the check costs the (EIP-170-bound) executor no runtime bytes.
        (bool ok, bytes memory ret) = executor_.staticcall(
            abi.encodeWithSelector(IStargateTransportProbe.STARGATE_POOL.selector)
        );
        if (!ok || ret.length != 32 || abi.decode(ret, (address)) == address(0)) {
            revert CrosschainCommandFuseWrongTransport(executor_);
        }
    }
}

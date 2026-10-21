// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "../../IFuseCommon.sol";
import {Command, CrosschainMessages} from "../../../crosschain/lib/CrosschainMessages.sol";
import {BusinessAction} from "../../../crosschain/lib/CrosschainConstants.sol";
import {ICrosschainExecutor} from "../../../crosschain/interfaces/ICrosschainExecutor.sol";
import {ICcipCrosschainExecutor, CcipRouteConfig} from "../../../crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {ICrosschainExecutorMetadata} from "../../../crosschain/common/ICrosschainExecutorMetadata.sol";
import {CrosschainTransportKind} from "../../../crosschain/common/CrosschainTransportTypes.sol";
import {CrosschainSubstrateLib} from "../lib/CrosschainSubstrateLib.sol";
import {CrosschainRecoveryLib} from "../lib/CrosschainRecoveryLib.sol";

interface ICcipFactoryFuse {
    function requestDispatcher(
        address executor_,
        uint256 dstChainId_,
        address[] calldata vaults_,
        uint256 maxFee_
    ) external returns (bytes32);
    function cancelExpiredDeployment(address executor_, uint256 dstChainId_) external;
}

interface ICcipCommandActionFuse {
    /// @dev Business action stored with a command id (0 for an unknown id / config update).
    function commandAction(bytes32 id_) external view returns (uint8);
    /// @dev Target vault of the DEPOSIT stored with a command id (0 for any other action / an unknown id).
    function commandDepositTarget(bytes32 id_) external view returns (address);
}

interface ICcipExecutorConfigFuse {
    function FACTORY() external view returns (address);
}

interface ICcipFactoryRouteFuse {
    function registerExecutorRoute(address executor_, uint256 chainId_, CcipRouteConfig calldata route_) external;
}

enum CcipCommandType {
    UNDEFINED,
    REGISTER_ROUTE,
    CREATE_DISPATCHER,
    UPDATE_VAULTS,
    SEND_COMMAND,
    REFRESH_BALANCE,
    CANCEL_RETURN,
    RETRY_COMMAND,
    CANCEL_COMMAND,
    CANCEL_DEPLOYMENT
}

struct CcipCommandFuseEnterData {
    CcipCommandType commandType;
    address executor;
    uint256 chainId;
    CcipRouteConfig route;
    address[] plasmaVaults;
    bool vaultsAllowed;
    /// @dev When true the remote allowlist is replaced by `plasmaVaults` instead of being
    ///      amended in place, matching the Stargate `UPDATE_PLASMA_VAULTS` semantics.
    bool vaultsReplace;
    /// @dev SEND_COMMAND only. Asset amounts inside `command.actionData` (DEPOSIT amount, REDEEM /
    ///      REDEEM_FROM_REQUEST `minAssets`) are in LOCAL ASSET decimals: the CCIP executor converts them to
    ///      shared decimals (`CcipDecimalsLib.normalizeActionData`, reverting on sub-precision dust) before the
    ///      dispatcher sees them (the dispatcher applies `_toLD` to `minAssets`). Share amounts are never
    ///      converted, including REQUEST_SHARES `shares` and its `maxFeeShares` fee ceiling (share units,
    ///      `type(uint256).max` = no ceiling; IL-8603).
    ///      The Stargate command fuse differs only in who converts: its `amount` and `minAssets` are already
    ///      shared decimals and forwarded verbatim. On the wire both transports carry shared decimals and both
    ///      dispatchers apply `_toLD` to `minAssets` (IL-8609).
    ///      `command.minExecutionGas` (IL-8625) is CHECK-ONLY on CCIP: 0 = none; non-zero must not exceed the budget the
    ///      executor derives from the route's gas limit (reverts `CommandBudgetAboveLane`) nor `MAX_COMMAND_EXECUTION_GAS`
    ///      (`CommandBudgetAboveMax`), and the derived budget, never the requested value, is stamped. It cannot buy more
    ///      gas than the route policy delivers; that needs a timelocked policy raise. RETRY_COMMAND and CANCEL_COMMAND
    ///      ignore it (a retry re-runs the stored budget).
    Command command;
    uint256 maxFee;
    address feeToken;
    /// @dev 0 = route policy; above policy is clamped; below policy reverts (`CcipGasLimitBelowRoutePolicy`).
    uint256 gasLimit;
}

/// @dev `UPDATE_VAULTS` that can add a vault (`vaultsAllowed` with a non-empty list; an empty replace-all only
///      removes vaults and stays allowed) and `SEND_COMMAND` with a DEPOSIT action revert
///      `CommandFuseChainBlocked` while the executor has circuit-broken the destination chain (IL-8580):
///      remote idle yield excluded from NAV must not be deployed further. REDEEM / REQUEST_SHARES /
///      REDEEM_FROM_REQUEST, CANCEL_COMMAND, CANCEL_RETURN and REFRESH_BALANCE stay open as repair and observe
///      actions. `RETRY_COMMAND` reads the stored command's action from the executor (`commandAction(commandId)`,
///      IL-8600) and is gated like a fresh send of that action. A retried DEPOSIT is refused on a blocked chain,
///      re-checks its target vault against the REMOTE_VAULT substrates (`commandDepositTarget(commandId)`: the
///      substrate may have been revoked since the first send) and takes the new exposure marker and the live
///      `getBalance()` NAV read that reverts when fail-closed. A retried REDEEM / REQUEST_SHARES /
///      REDEEM_FROM_REQUEST stays a recovery. A retried UPDATE_VAULTS is not recovery-marked, so like a fresh one
///      it is unavailable while NAV is fail-closed, and it is refused on a blocked chain whatever its list, because
///      the executor does not store the list. On a blocked chain `CANCEL_COMMAND` and a fresh pure-removal update
///      stay available; while NAV is fail-closed only `CANCEL_COMMAND` does.
///      The supply path on a blocked chain is not checked here: it is stopped by the `ChainBlocked` revert of the
///      executor's `balanceByChain`, either in the supply fuse's live `getBalance()` read or, when the chain held
///      no value, in the end-of-transaction NAV refresh after the send booked `outboundInFlight`; there is no
///      explicit executor check. `REFRESH_BALANCE` is metered by the executor (one outstanding request and a
///      `BALANCE_REQUEST_COOLDOWN` per chain, IL-8579) and may revert `BalanceRequestOutstanding` /
///      `BalanceRequestCooldown`.
/// @dev `CANCEL_DEPLOYMENT` (IL-8637 R1) calls the factory's `cancelExpiredDeployment` from the vault, the
///      executor's MANAGER, so the vault can use the exclusive cancel window (owner and manager from
///      `createdAt + DEPLOYMENT_TTL + DEPLOYMENT_CANCEL_MARGIN`, everyone else `DEPLOYMENT_CANCEL_GRACE` later). It is
///      not recovery-marked, like `CREATE_DISPATCHER`: a pending CCIP ticket blocks only its own executor and chain,
///      the factory owner can cancel without the vault, and every recovery-marked command widens the surface on which
///      the cached / unchecked NAV fallback is served (IL-8611). The Stargate `CANCEL_DISPATCHER_REQUEST` is
///      recovery-marked because a pending Stargate request freezes factory-wide asset and path config (IL-8259).
///      Consequence: while NAV is fail-closed the vault cannot cancel on its own (the factory owner, or anyone after
///      `DEPLOYMENT_CANCEL_GRACE`, can); batched with a recovery-marked command such as `REFRESH_BALANCE` it goes
///      through, which is harmless since a cancel moves no value.
///      UPDATE_VAULTS removal warning (IL-8784, D-060 / D-065): redeem or recall the position to zero BEFORE removing
///      a vault. A removed vault is swept best effort and always untracked, so a failed sweep drops the residual shares
///      out of NAV until the vault is allowlisted again; alert on the dispatcher's `TrackedVaultSweepResidual` event.
///      On tight lanes send ONE removal per UPDATE_VAULTS and adds in a separate command.
contract CcipCrosschainCommandFuse is IFuseCommon {
    /// @notice Emitted after a manager operation is forwarded to the executor.
    /// @dev Same signature as the Stargate command fuse's event, so one topic0 covers both transports.
    ///      Emitted from the vault (delegatecall context).
    /// @param version The address of this fuse contract version.
    /// @param executor The CcipCrosschainExecutor driven.
    /// @param commandType The forwarded operation discriminator (`CcipCommandType`).
    /// @param chainId The target/destination chainId of the operation.
    event CrosschainCommandFuseEnter(address version, address executor, uint8 commandType, uint256 chainId);

    error CcipCommandFuseExecutorManagerMismatch(address executor, address manager);
    error CcipCommandFuseWrongTransport(address executor);
    error CcipCommandFuseUnsupportedCommand(uint8 commandType);
    /// @notice A fresh DEPOSIT or an allowlist-adding (non-empty) UPDATE_VAULTS, or a retry of a DEPOSIT or of any
    ///         UPDATE_VAULTS, targeted a chain the executor has blocked.
    error CommandFuseChainBlocked(address executor, uint256 chainId);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(CcipCommandFuseEnterData calldata data_) external {
        _validate(data_.executor);
        if (data_.commandType == CcipCommandType.REGISTER_ROUTE) {
            ICcipFactoryRouteFuse(ICcipExecutorConfigFuse(data_.executor).FACTORY()).registerExecutorRoute(
                data_.executor,
                data_.chainId,
                data_.route
            );
        } else if (data_.commandType == CcipCommandType.CREATE_DISPATCHER) {
            CrosschainSubstrateLib.validateRemoteVaultsGranted(MARKET_ID, data_.chainId, data_.plasmaVaults);
            ICcipFactoryFuse(ICrosschainExecutorMetadata(data_.executor).FACTORY()).requestDispatcher(
                data_.executor,
                data_.chainId,
                data_.plasmaVaults,
                data_.maxFee
            );
        } else if (data_.commandType == CcipCommandType.UPDATE_VAULTS) {
            if (data_.vaultsAllowed && data_.plasmaVaults.length != 0) {
                _requireChainNotBlocked(data_.executor, data_.chainId);
                CrosschainSubstrateLib.validateRemoteVaultsGranted(MARKET_ID, data_.chainId, data_.plasmaVaults);
            }
            ICcipCrosschainExecutor(data_.executor).updateVaults(
                data_.chainId,
                data_.plasmaVaults,
                data_.vaultsAllowed,
                data_.vaultsReplace,
                data_.maxFee,
                data_.feeToken,
                data_.gasLimit
            );
        } else if (data_.commandType == CcipCommandType.SEND_COMMAND) {
            if (data_.command.action == uint8(BusinessAction.DEPOSIT)) {
                _requireChainNotBlocked(data_.executor, data_.chainId);
            }
            _validateCommandTargetVault(data_.chainId, data_.command);
            _gateOrMarkBusinessAction(ICrosschainExecutor(data_.executor), data_.command.action);
            ICcipCrosschainExecutor(data_.executor).sendCommandToDispatcher(
                data_.chainId,
                data_.command,
                data_.maxFee,
                data_.feeToken,
                data_.gasLimit
            );
        } else if (data_.commandType == CcipCommandType.REFRESH_BALANCE) {
            // IL-8612: a balance request moves no value, so it is recovery-marked and stays usable while live NAV
            // is fail-closed (the diagnostic that explains why). Config commands above remain blocked.
            CrosschainRecoveryLib.markRecovery(MARKET_ID, data_.executor);
            ICcipCrosschainExecutor(data_.executor).requestRemoteBalance(
                data_.chainId,
                data_.maxFee,
                data_.feeToken,
                data_.gasLimit
            );
        } else if (data_.commandType == CcipCommandType.CANCEL_RETURN) {
            CrosschainRecoveryLib.markRecovery(MARKET_ID, data_.executor);
            ICcipCrosschainExecutor(data_.executor).cancelPendingReturn(data_.chainId);
        } else if (data_.commandType == CcipCommandType.RETRY_COMMAND) {
            // IL-8600: a retry replays the stored command, so it is gated like a fresh send of the same action.
            uint8 storedAction = ICcipCommandActionFuse(data_.executor).commandAction(data_.command.commandId);
            // A config update (action 0) may add vaults and the executor does not store its list, so any retried
            // config update is refused on a blocked chain, as a fresh DEPOSIT or a fresh vault add would be.
            if (storedAction == uint8(BusinessAction.DEPOSIT) || storedAction == 0) {
                _requireChainNotBlocked(data_.executor, data_.chainId);
            }
            // The DEPOSIT target was checked at the first send only; its substrate may have been revoked since.
            if (storedAction == uint8(BusinessAction.DEPOSIT)) {
                CrosschainSubstrateLib.validateRemoteVaultGranted(
                    MARKET_ID,
                    data_.chainId,
                    ICcipCommandActionFuse(data_.executor).commandDepositTarget(data_.command.commandId)
                );
            }
            _gateOrMarkBusinessAction(ICrosschainExecutor(data_.executor), storedAction);
            ICcipCrosschainExecutor(data_.executor).retryCommand(
                data_.chainId,
                data_.command.commandId,
                data_.maxFee,
                data_.feeToken,
                data_.gasLimit
            );
        } else if (data_.commandType == CcipCommandType.CANCEL_COMMAND) {
            CrosschainRecoveryLib.markRecovery(MARKET_ID, data_.executor);
            ICcipCrosschainExecutor(data_.executor).cancelCommand(
                data_.chainId,
                data_.command.commandId,
                data_.maxFee,
                data_.feeToken,
                data_.gasLimit
            );
        } else if (data_.commandType == CcipCommandType.CANCEL_DEPLOYMENT) {
            ICcipFactoryFuse(ICrosschainExecutorMetadata(data_.executor).FACTORY()).cancelExpiredDeployment(
                data_.executor,
                data_.chainId
            );
        } else {
            revert CcipCommandFuseUnsupportedCommand(uint8(data_.commandType));
        }

        emit CrosschainCommandFuseEnter(VERSION, data_.executor, uint8(data_.commandType), data_.chainId);
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

    function _requireChainNotBlocked(address executor_, uint256 chainId_) private view {
        if (ICcipCrosschainExecutor(executor_).chainBlocked(chainId_)) {
            revert CommandFuseChainBlocked(executor_, chainId_);
        }
    }

    function _validate(address executor_) private view {
        CrosschainSubstrateLib.validateExecutorGranted(MARKET_ID, executor_);
        address manager = ICrosschainExecutor(executor_).MANAGER();
        if (manager != address(this)) revert CcipCommandFuseExecutorManagerMismatch(executor_, manager);
        if (ICrosschainExecutorMetadata(executor_).transportKind() != CrosschainTransportKind.CHAINLINK_CCIP) {
            revert CcipCommandFuseWrongTransport(executor_);
        }
    }

    function _validateCommandTargetVault(uint256 chainId_, Command calldata command_) private view {
        address targetVault;
        if (command_.action == uint8(BusinessAction.DEPOSIT)) {
            (targetVault, , ) = CrosschainMessages.decodeDepositAction(command_.actionData);
        } else if (command_.action == uint8(BusinessAction.REDEEM)) {
            (targetVault, , ) = CrosschainMessages.decodeRedeemAction(command_.actionData);
        } else if (command_.action == uint8(BusinessAction.REQUEST_SHARES)) {
            (, targetVault, , ) = CrosschainMessages.decodeRequestSharesAction(command_.actionData);
        } else if (command_.action == uint8(BusinessAction.REDEEM_FROM_REQUEST)) {
            (, targetVault, , , ) = CrosschainMessages.decodeRedeemFromRequestAction(command_.actionData);
        } else {
            return;
        }
        CrosschainSubstrateLib.validateRemoteVaultGranted(MARKET_ID, chainId_, targetVault);
    }
}

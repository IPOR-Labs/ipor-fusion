// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {CrosschainErrors} from "../../lib/CrosschainErrors.sol";
import {CrosschainMessages, SweepFloor} from "../../lib/CrosschainMessages.sol";
import {CrosschainVaultActionLib} from "../../lib/CrosschainVaultActionLib.sol";
import {CcipMessages, CcipMsgType} from "./CcipMessages.sol";
import {ICcipWithdrawManager} from "../interfaces/ICcipWithdrawManager.sol";

/// @title CcipDispatcherLib
/// @notice Linked vault-set management for the CCIP dispatcher: allowlist/tracked-set configuration and the
///         best-effort sweep of vaults that leave the allowlist. Also the response-queue entry (`QueuedResponse`)
///         and the helper that raises the dispatcher balances carried by queued responses when a queued token
///         amount stays on the dispatcher instead of leaving it, and the body of the `REQUEST_SHARES` command
///         (IL-9621).
/// @dev This is an external linked library that keeps `CcipCrosschainDispatcher` below EIP-170. It runs through
///      delegatecall on the dispatcher's own storage: the vault mappings, the tracked array and the response queue
///      are passed by storage reference, so every slot stays where the dispatcher declares it, and `address(this)`
///      is the dispatcher. The events and `RequestSharesFeeExceeded` are declared here because they are emitted or
///      raised from this library; their signatures mirror the dispatcher's own declarations, so topics and
///      selectors are identical. The queue helper declares no error of its own: it raises only
///      `CcipMessages.InvalidVersion` / `InvalidMessageType` (both declared in `CcipMessages`) and the
///      checked-arithmetic panic.
///
///      Tracked set == allowlist (IL-8784, D-020 / D-028): a vault is tracked the moment it is allowlisted and,
///      when it leaves the allowlist, the library redeems its whole position into the dispatcher's idle balance
///      (`CrosschainVaultActionLib.sweepShares`) and untracks it, whatever the sweep left behind. A residual
///      is reported by `TrackedVaultSweepResidual` and drops out of NAV until the vault is allowlisted again, so
///      ALPHA must withdraw or recall a position BEFORE removing its vault.
///      The one exception is a sweep floor (IL-9629): a vault whose non-zero `SweepFloor` is not reached
///      (`SWEEP_BELOW_MIN`, nothing redeemed; IL-9694 D-002: also a redeem that reverted with error data: the
///      vault's own error or a gas-starved inner call such as FailedInnerCall) leaves the allowlist but STAYS
///      TRACKED, so its position keeps counting in NAV and ALPHA exits it with a REDEEM. Such a retained vault
///      (tracked, off the allowlist when a command starts)
///      is swept again only by a command that names it in a `SweepFloor` entry (a floor of 0 forces the removal).
library CcipDispatcherLib {
    /// @notice One queued dispatcher -> executor response.
    /// @dev `data` is the `CcipMessages` envelope that is sent as it is stored. `amountLD` is the bridged token amount
    ///      in LOCAL ASSET decimals (it is what the CCIP message carries); the sibling accounting values are SHARED
    ///      decimals: the dispatcher's `queuedTokenAmount` and `trackedIdle`, and the amounts and balances inside the
    ///      payloads. `returnDeadline` is the recall deadline of a `RETURN_TRANSFER` that stayed queued (IL-9621), 0
    ///      for every other entry; it lives in the entry, so deleting the entry clears it on every path.
    struct QueuedResponse {
        bytes data;
        uint256 amountLD;
        uint256 returnDeadline;
    }

    event VaultAllowed(address vault, bool allowed);
    event VaultTracked(address vault);
    event VaultUntracked(address vault);
    /// @dev Mirrors `CcipCrosschainDispatcher.SharesRequested`; emitted by `requestShares`.
    event SharesRequested(address vault, uint256 pendingShares, uint256 feeShares);

    /// @dev Mirrors `CcipCrosschainDispatcher.RequestSharesFeeExceeded`; raised by `requestShares`.
    error RequestSharesFeeExceeded(address vault, uint256 deducted, uint256 shares, uint256 maxFeeShares);

    /// @dev Must equal `CcipCrosschainDispatcher.MAX_TRACKED_VAULTS`.
    uint256 internal constant MAX_TRACKED_VAULTS = 32;

    /// @notice Raises by `amountSD_` the dispatcher balance carried by every queued response from `firstId_` to
    ///         `lastId_` (inclusive) that carries one (IL-9621).
    /// @dev For a token amount that leaves the response queue for `trackedIdle` without being sent (a released recall
    ///      return, `unwindQueuedReturn`, or a dropped token-bearing head). Every balance in the queue was encoded net
    ///      of the queued token amounts, which it expects to leave first; once such an amount stays on the dispatcher
    ///      instead, each later balance must grow by it, or the executor would anchor on a figure that is too low.
    ///      Each entry's envelope is decoded with `CcipMessages.decode` and its payload with a typed `abi.decode`;
    ///      exactly one word is raised and the entry is re-encoded with `CcipMessages.encode`:
    ///      - `TRANSFER_SETTLED`, `RETURN_TRANSFER`: `(bytes32 operationId, uint256 amount, uint256 remoteBalance,
    ///        uint64 version)`, the third word;
    ///      - `BALANCE_REPORT`: `(uint256 remoteBalance, uint64 stateVersion)`, the first word;
    ///      - `COMMAND_ACK`: `(bytes32 commandId, uint64 sequence, int256 delta, uint256 remoteBalance, uint64 version,
    ///        uint64 configEpoch, uint8 resolution)`, the fourth word.
    ///      `RETURN_REJECTED`, `COMMAND_NACK` and every type the dispatcher does not queue carry no balance and are not
    ///      written. A new response type that carries a dispatcher balance must be added here. `amountLD`,
    ///      `returnDeadline`, the ids and the order are never touched. An empty range (`firstId_ > lastId_`) or
    ///      `amountSD_ == 0` does nothing and reads nothing. Every id of a non-empty range must hold a live entry (the
    ///      dispatcher passes ids between its head and its tail): a deleted entry reverts in the envelope decode.
    /// @param queue_ The dispatcher's response queue.
    /// @param firstId_ The first response id to raise.
    /// @param lastId_ The last response id to raise (inclusive), normally the queue tail.
    /// @param amountSD_ The amount, in shared decimals, added to each carried balance.
    function raiseQueuedBalances(
        mapping(uint64 => QueuedResponse) storage queue_,
        uint64 firstId_,
        uint64 lastId_,
        uint256 amountSD_
    ) public {
        if (amountSD_ == 0 || firstId_ > lastId_) return;
        // Stops at `lastId_` before incrementing, so the counter never passes `type(uint64).max`.
        for (uint64 id = firstId_; ; ++id) {
            _raiseQueuedBalance(queue_[id], amountSD_);
            if (id == lastId_) return;
        }
    }

    /// @notice Releases the `RETURN_TRANSFER` at `headId_` without its tokens (IL-9621): the response keeps its
    ///         operation id and version, carries amount 0 and a balance raised by the released amount, and every
    ///         queued response from `headId_ + 1` to `lastId_` has its carried balance raised by the same amount.
    /// @dev The entry at `headId_` must be a `RETURN_TRANSFER`, otherwise `CcipMessages.InvalidMessageType` with its
    ///      raw type. Its payload `(operationId, amount, remoteBalance, version)` becomes `(operationId, 0,
    ///      remoteBalance + amount, version)` and its `amountLD` is zeroed; no vault is read, the balance is the one
    ///      encoded when the return was queued (net of the amount) plus the amount. `returnDeadline` is left as it is:
    ///      the caller sends the entry, which deletes it. The entries behind are raised by `raiseQueuedBalances` rules.
    ///      The caller owns the ledgers (`queuedTokenAmount -= amountSD`, `trackedIdle += amountSD`), the event and
    ///      the send.
    /// @param queue_ The dispatcher's response queue.
    /// @param headId_ The response id of the return to release, the queue head.
    /// @param lastId_ The last response id to raise (inclusive), normally the queue tail.
    /// @return operationId The operation id of the released return.
    /// @return amountSD The released amount in shared decimals: the payload's `amount`.
    function unwindQueuedReturn(
        mapping(uint64 => QueuedResponse) storage queue_,
        uint64 headId_,
        uint64 lastId_
    ) public returns (bytes32 operationId, uint256 amountSD) {
        QueuedResponse storage head = queue_[headId_];
        (CcipMsgType messageType, bytes memory payload) = CcipMessages.decode(head.data);
        if (messageType != CcipMsgType.RETURN_TRANSFER) revert CcipMessages.InvalidMessageType(uint8(messageType));
        uint256 remoteBalance;
        uint64 version;
        (operationId, amountSD, remoteBalance, version) = abi.decode(payload, (bytes32, uint256, uint256, uint64));
        head.data = CcipMessages.encode(
            CcipMsgType.RETURN_TRANSFER,
            abi.encode(operationId, uint256(0), remoteBalance + amountSD, version)
        );
        head.amountLD = 0;
        // `headId_ < lastId_` also keeps `headId_ + 1` from overflowing.
        if (headId_ < lastId_) raiseQueuedBalances(queue_, headId_ + 1, lastId_, amountSD);
    }

    /// @dev One entry of `raiseQueuedBalances` (layouts there): a type that carries no balance is not written.
    function _raiseQueuedBalance(QueuedResponse storage entry_, uint256 amountSD_) private {
        (CcipMsgType messageType, bytes memory payload) = CcipMessages.decode(entry_.data);
        if (messageType == CcipMsgType.TRANSFER_SETTLED || messageType == CcipMsgType.RETURN_TRANSFER) {
            (bytes32 operationId, uint256 amount, uint256 remoteBalance, uint64 version) = abi.decode(
                payload,
                (bytes32, uint256, uint256, uint64)
            );
            payload = abi.encode(operationId, amount, remoteBalance + amountSD_, version);
        } else if (messageType == CcipMsgType.BALANCE_REPORT) {
            (uint256 remoteBalance, uint64 stateVersion) = abi.decode(payload, (uint256, uint64));
            payload = abi.encode(remoteBalance + amountSD_, stateVersion);
        } else if (messageType == CcipMsgType.COMMAND_ACK) {
            payload = _raisedCommandAck(payload, amountSD_);
        } else {
            return;
        }
        entry_.data = CcipMessages.encode(messageType, payload);
    }

    /// @dev The `COMMAND_ACK` payload with its fourth word, the dispatcher balance, raised by `amountSD_`.
    function _raisedCommandAck(bytes memory payload_, uint256 amountSD_) private pure returns (bytes memory) {
        (
            bytes32 commandId,
            uint64 sequence,
            int256 delta,
            uint256 remoteBalance,
            uint64 version,
            uint64 configEpoch,
            uint8 resolution
        ) = abi.decode(payload_, (bytes32, uint64, int256, uint256, uint64, uint64, uint8));
        return abi.encode(commandId, sequence, delta, remoteBalance + amountSD_, version, configEpoch, resolution);
    }

    /// @notice Adds or removes `vaults_` from the deposit allowlist, optionally replacing the whole allowlist.
    /// @dev Three passes. 1) Validate and flag: `replace_` first clears every allowlist flag, then each vault is
    ///      validated (code and underlying asset, only when ADDING so a vault that reverts on every call stays
    ///      removable) and flagged. 2) Sweep: every tracked vault that is no longer allowed is swept with its
    ///      `floors_` entry (no floor without one) and untracked unless the floor was not reached (reverse iteration,
    ///      because removal swap-and-pops); a vault retained below a floor before this command is skipped unless
    ///      `floors_` names it (IL-9629). It runs for a removal, a replace, or any command carrying floors. 3) Track:
    ///      only now are the newly allowed vaults tracked (cap-checked), so a replace at the 32-vault cap frees the
    ///      slots of the vaults it removes first (IL-8629); a retained vault keeps its slot.
    /// @param isAllowed_ The dispatcher's allowlist flags.
    /// @param isTracked_ The dispatcher's tracked-set flags.
    /// @param indexPlusOne_ The dispatcher's index-plus-one map into `tracked_`.
    /// @param tracked_ The dispatcher's tracked vault array.
    /// @param asset_ The dispatcher's underlying asset every allowlisted vault must share.
    /// @param vaults_ The vaults to add or remove.
    /// @param allowed_ True to allowlist `vaults_`, false to remove them.
    /// @param replace_ True to clear the existing allowlist before applying `vaults_`.
    /// @param floors_ The sweep floors, `minAssets` in shared decimals (IL-9629); empty for the factory bootstrap.
    /// @param rate_ The dispatcher's `DECIMAL_CONVERSION_RATE` (shared to local decimals).
    /// @return sweptAssetsLD The `asset_` the sweeps put back into the dispatcher's balance, local decimals. The
    ///         caller must credit it to `trackedIdle`.
    function configureVaults(
        mapping(address => bool) storage isAllowed_,
        mapping(address => bool) storage isTracked_,
        mapping(address => uint256) storage indexPlusOne_,
        address[] storage tracked_,
        address asset_,
        address[] memory vaults_,
        bool allowed_,
        bool replace_,
        SweepFloor[] memory floors_,
        uint256 rate_
    ) public returns (uint256 sweptAssetsLD) {
        bool sweeps = !allowed_ || replace_ || floors_.length != 0;
        // IL-9629: the vaults retained below a floor by an earlier command, read before this command moves any flag.
        address[] memory retained;
        if (sweeps) retained = _retained(isAllowed_, tracked_);
        _flag(isAllowed_, tracked_, asset_, vaults_, allowed_, replace_);
        if (sweeps) sweptAssetsLD = _sweep(isAllowed_, isTracked_, indexPlusOne_, tracked_, retained, floors_, rate_);
        if (allowed_) _track(isTracked_, indexPlusOne_, tracked_, vaults_);
    }

    /// @dev Pass 1 of `configureVaults`: clear (replace) and set the allowlist flags.
    function _flag(
        mapping(address => bool) storage isAllowed_,
        address[] storage tracked_,
        address asset_,
        address[] memory vaults_,
        bool allowed_,
        bool replace_
    ) private {
        if (replace_) {
            uint256 trackedLen = tracked_.length;
            for (uint256 i; i < trackedLen; ++i) {
                address tracked = tracked_[i];
                if (isAllowed_[tracked]) {
                    isAllowed_[tracked] = false;
                    emit VaultAllowed(tracked, false);
                }
            }
        }
        for (uint256 i; i < vaults_.length; ++i) {
            address vault = vaults_[i];
            if (vault == address(0) || (allowed_ && (vault.code.length == 0 || IERC4626(vault).asset() != asset_))) {
                revert CrosschainErrors.InvalidVault(vault);
            }
            isAllowed_[vault] = allowed_;
            emit VaultAllowed(vault, allowed_);
        }
    }

    /// @dev Pass 2 of `configureVaults`: sweep every tracked vault that is off the allowlist and untrack it, unless it
    ///      is a retained vault without an entry (skipped) or its floor was not reached (kept tracked, IL-9629). The
    ///      floor is converted from shared to local decimals with saturation: an unreachable floor means "never sell".
    function _sweep(
        mapping(address => bool) storage isAllowed_,
        mapping(address => bool) storage isTracked_,
        mapping(address => uint256) storage indexPlusOne_,
        address[] storage tracked_,
        address[] memory retained_,
        SweepFloor[] memory floors_,
        uint256 rate_
    ) private returns (uint256 sweptAssetsLD) {
        for (uint256 i = tracked_.length; i > 0; --i) {
            address vault = tracked_[i - 1];
            if (isAllowed_[vault]) continue;
            (bool skip, uint256 minAssetsSD) = CrosschainMessages.sweepFloorFor(floors_, retained_, vault);
            if (skip) continue;
            // A floor above `type(uint256).max / rate_` can never be met: saturate it (reason 6, vault kept) instead of
            // letting the checked multiply panic and NACK the whole command (Stargate parity).
            (, uint256 assetsLD, , uint8 reason, ) = CrosschainVaultActionLib.sweepShares(
                vault,
                minAssetsSD > type(uint256).max / rate_ ? type(uint256).max : minAssetsSD * rate_
            );
            sweptAssetsLD += assetsLD;
            if (reason != CrosschainVaultActionLib.SWEEP_BELOW_MIN) {
                _removeTracked(isTracked_, indexPlusOne_, tracked_, vault);
            }
        }
    }

    /// @dev Pass 3 of `configureVaults`: track the newly allowed vaults (cap-checked).
    function _track(
        mapping(address => bool) storage isTracked_,
        mapping(address => uint256) storage indexPlusOne_,
        address[] storage tracked_,
        address[] memory vaults_
    ) private {
        for (uint256 i; i < vaults_.length; ++i) {
            address vault = vaults_[i];
            if (isTracked_[vault]) continue;
            if (tracked_.length >= MAX_TRACKED_VAULTS) revert CrosschainErrors.VaultsCapReached(MAX_TRACKED_VAULTS);
            isTracked_[vault] = true;
            tracked_.push(vault);
            indexPlusOne_[vault] = tracked_.length;
            emit VaultTracked(vault);
        }
    }

    /// @dev The tracked vaults that are off the allowlist (IL-9629: retained below a floor by an earlier command; every
    ///      other path keeps the tracked set inside the allowlist). Allowlisted vaults are left as zero padding.
    function _retained(
        mapping(address => bool) storage isAllowed_,
        address[] storage tracked_
    ) private view returns (address[] memory retained) {
        uint256 len = tracked_.length;
        retained = new address[](len);
        for (uint256 i; i < len; ++i) {
            address vault = tracked_[i];
            if (!isAllowed_[vault]) retained[i] = vault;
        }
    }

    function _removeTracked(
        mapping(address => bool) storage isTracked_,
        mapping(address => uint256) storage indexPlusOne_,
        address[] storage tracked_,
        address vault_
    ) private {
        uint256 index = indexPlusOne_[vault_] - 1;
        uint256 last = tracked_.length - 1;
        if (index != last) {
            address moved = tracked_[last];
            tracked_[index] = moved;
            indexPlusOne_[moved] = index + 1;
        }
        tracked_.pop();
        delete indexPlusOne_[vault_];
        delete isTracked_[vault_];
        emit VaultUntracked(vault_);
    }

    /// @notice Runs a `REQUEST_SHARES` command of the dispatcher against a tracked vault: registers (replaces) the
    ///         dispatcher's withdraw request for `shares` of `vault` at its WithdrawManager and bounds the fee taken.
    /// @dev The body of the dispatcher's `REQUEST_SHARES` branch, moved here unchanged to keep the dispatcher below
    ///      EIP-170 (IL-9621). It runs under delegatecall inside the dispatcher's `runStoredCommand` self-call, so
    ///      `address(this)` is the dispatcher, every external call is made by the dispatcher, and a revert bubbles up
    ///      unchanged and is the business failure the dispatcher NACKs. Order: decode; tracked-set gate
    ///      (`VaultNotTracked`); manager check (`CrosschainVaultActionLib.requireVaultWithdrawManager`); share balance
    ///      (`RequestSharesUnavailable`); `requestShares`; fee bound (`RequestSharesFeeExceeded`); read-back of the
    ///      outstanding request; `SharesRequested`. No value moves, so the caller's delta is 0.
    /// @param isTracked_ The dispatcher's tracked-set flags.
    /// @param actionData_ The command's action data: ABI-encoded `(address withdrawManager, address vault,
    ///        uint256 shares, uint256 maxFeeShares)` (`CrosschainMessages.decodeRequestSharesAction`).
    function requestShares(mapping(address => bool) storage isTracked_, bytes memory actionData_) public {
        (address withdrawManager, address vault, uint256 shares, uint256 maxFeeShares) = CrosschainMessages
            .decodeRequestSharesAction(actionData_);
        // Gate on the TRACKED set, not the allowlist: a vault removed from the deposit allowlist may
        // still hold a live position that has to be unwound (matches Stargate, audit L-3).
        if (!isTracked_[vault]) revert CrosschainErrors.VaultNotTracked(vault);
        CrosschainVaultActionLib.requireVaultWithdrawManager(vault, withdrawManager);
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
        // The WithdrawManager REPLACES its stored request on `requestShares`, except that it refuses (IL-9652,
        // `WithdrawManagerReleasedRequestPending`) a repeat while the previous request is released and inside
        // its window: REDEEM_FROM_REQUEST first. It takes the fee out of
        // this contract's shares, so the event reports the manager's read-back outstanding request. The
        // dispatcher keeps no copy (IL-8410): the manager bounds REDEEM_FROM_REQUEST and `balanceOf` alone
        // proves a live position.
        emit SharesRequested(vault, afterShares, deducted);
    }
}

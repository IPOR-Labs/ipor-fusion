// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {CrosschainConstants} from "../../lib/CrosschainConstants.sol";
import {UpdateVaults} from "../../lib/CrosschainMessages.sol";
import {CrosschainErrors} from "../../lib/CrosschainErrors.sol";
import {TrackedVaultPricingLib} from "../../lib/TrackedVaultPricingLib.sol";
import {CrosschainVaultActionLib} from "../../lib/CrosschainVaultActionLib.sol";

/// @title StargateDispatcherLib
/// @notice Linked vault-allowlist update (with the tracked-set reconcile), tracked-set hash, force-untrack and
///         rescue-ledger check for the Stargate dispatcher.
/// @dev This is an external linked library that keeps `StargateCrosschainDispatcher` below EIP-170. It runs
///      through delegatecall on the dispatcher's own storage, which is passed by storage reference so every
///      slot stays where the dispatcher declares it; `address(this)` is the dispatcher. The events are declared
///      here because they are emitted from this library; their signatures mirror the dispatcher's own
///      declarations, so topics are identical.
library StargateDispatcherLib {
    event VaultsUpdated(uint64 commandConfigEpoch, uint64 stateVersion, uint256 count);
    event TrackedVaultWrittenOff(address vault, uint256 sharesLeft);

    /// @notice Applies a decoded `UPDATE_VAULTS`: replaces the deposit allowlist, then reconciles the tracked-position
    ///         set with it (IL-8784), and returns the ASSET the sweeps put back into the dispatcher.
    /// @dev One linked call for both steps (EIP-170). The dispatcher stores `currentEpoch_ + 1` as its config epoch
    ///      BEFORE this call; the epoch check in `_replaceAllowlist` reverts the whole gas-bounded self-call on a
    ///      mismatch, so that write is rolled back with everything else, and the sweeps' external calls see the new
    ///      epoch exactly as when the dispatcher stored the returned epoch between two calls.
    ///      The read-only `asset()` checks now run after the dispatcher's epoch write; this is harmless because they
    ///      are read-only and any revert rolls back the whole self-call.
    /// @param allowed_ The dispatcher's allowlist array.
    /// @param isAllowed_ The dispatcher's allowlist flags.
    /// @param isTracked_ The dispatcher's tracked-set flags.
    /// @param tracked_ The dispatcher's tracked vault array.
    /// @param currentEpoch_ The dispatcher's command config epoch before this update.
    /// @param stateVersion_ The dispatcher's state version, carried into `VaultsUpdated`.
    /// @param asset_ The dispatcher's underlying asset every allowlisted vault must share.
    /// @param data_ The ABI-encoded `UpdateVaults` payload.
    /// @return sweptAssetsLD The ASSET the sweeps put back into the dispatcher's balance, local decimals. The
    ///         caller must credit it to `trackedIdle`.
    function applyUpdateVaults(
        address[] storage allowed_,
        mapping(address => bool) storage isAllowed_,
        mapping(address => bool) storage isTracked_,
        address[] storage tracked_,
        uint64 currentEpoch_,
        uint64 stateVersion_,
        address asset_,
        bytes calldata data_
    ) public returns (uint256 sweptAssetsLD) {
        _replaceAllowlist(allowed_, isAllowed_, currentEpoch_, stateVersion_, asset_, data_);
        sweptAssetsLD = _reconcileTracked(allowed_, isAllowed_, isTracked_, tracked_);
    }

    /// @notice Canonical tracked-position-set hash bound by attestations (body of the dispatcher's
    ///         `_trackedPositionSetHash`, moved here for EIP-170).
    /// @dev Runs through delegatecall, so `address(this)` is the dispatcher and the hash is the one the
    ///      dispatcher computed itself: `keccak256(abi.encode(dispatcher, block.chainid, trackedPositionVaults))`.
    /// @param tracked_ The dispatcher's tracked vault array.
    /// @return The tracked-position-set hash.
    function trackedPositionSetHash(address[] storage tracked_) public view returns (bytes32) {
        return keccak256(abi.encode(address(this), block.chainid, tracked_));
    }

    /// @notice Replaces the deposit allowlist with the decoded `UPDATE_VAULTS` set.
    /// @dev Clears the old allowlist flags (tracked live positions are untouched here; `_reconcileTracked` runs
    ///      next), requires `newConfigEpoch == currentEpoch_ + 1` and a set within `MAX_ALLOWED_VAULTS`, and
    ///      validates every new vault for real code and a matching underlying asset.
    /// @param allowed_ The dispatcher's allowlist array.
    /// @param isAllowed_ The dispatcher's allowlist flags.
    /// @param currentEpoch_ The dispatcher's command config epoch before this update.
    /// @param stateVersion_ The dispatcher's state version, carried into `VaultsUpdated`.
    /// @param asset_ The dispatcher's underlying asset every allowlisted vault must share.
    /// @param data_ The ABI-encoded `UpdateVaults` payload.
    function _replaceAllowlist(
        address[] storage allowed_,
        mapping(address => bool) storage isAllowed_,
        uint64 currentEpoch_,
        uint64 stateVersion_,
        address asset_,
        bytes calldata data_
    ) private {
        UpdateVaults memory u = abi.decode(data_, (UpdateVaults));
        if (u.newConfigEpoch != currentEpoch_ + 1) {
            revert CrosschainErrors.ConfigEpochMismatch(currentEpoch_ + 1, u.newConfigEpoch);
        }
        uint256 newLen = u.vaults.length;
        if (newLen > CrosschainConstants.MAX_ALLOWED_VAULTS) {
            revert CrosschainErrors.VaultsCapReached(CrosschainConstants.MAX_ALLOWED_VAULTS);
        }
        // Same end state as `delete allowedDepositVaults` (length 0, every element slot zeroed).
        for (uint256 i = allowed_.length; i != 0; --i) {
            isAllowed_[allowed_[i - 1]] = false;
            allowed_.pop();
        }
        for (uint256 i; i < newLen; ++i) {
            address v = u.vaults[i];
            if (v.code.length == 0) revert CrosschainErrors.InvalidVault(v);
            if (IERC4626(v).asset() != asset_) revert CrosschainErrors.InvalidVault(v);
            if (!isAllowed_[v]) {
                isAllowed_[v] = true;
                allowed_.push(v);
            }
        }
        emit VaultsUpdated(u.newConfigEpoch, stateVersion_, newLen);
    }

    /// @notice Reconciles the tracked-position set with the just-updated allowlist (IL-8784, D-020 / D-028).
    /// @dev Run right after `_replaceAllowlist`, inside the same gas-bounded self-call. Order matters (IL-8839,
    ///      D-071). Pass 1 re-tracks every allowlisted, untracked vault the dispatcher holds shares of (all gas-capped
    ///      reads AND the tracking writes), so re-allowlisting a vault with a residual resumes its valuation
    ///      immediately. Pass 2 sweeps (best-effort redeem into idle, `CrosschainVaultActionLib.sweepShares`) and
    ///      ALWAYS untracks every tracked vault that is no longer allowlisted, whatever the sweep left behind; a
    ///      residual is reported by `TrackedVaultSweepResidual` and stays outside NAV until the vault is allowlisted
    ///      again, so ALPHA must withdraw or recall a position BEFORE removing its vault. This also frees the slot of
    ///      an emptied vault (IL-8644). Running the reads first means that after a gas-limited sweep only the
    ///      removal's own bookkeeping remains (well inside `VAULT_SWEEP_RESERVE_GAS`), so a burned sweep can no longer
    ///      starve the re-track reads. The allowlist replace and the re-track pass still run before the sweep and must
    ///      fit the command budget: measured on committed state, the 2,500,000 minimum lane carries one burned-sweep
    ///      removal with 31 kept vaults with a thin margin (about 98k), and each newly tracked vault costs about 50k
    ///      of writes, so many simultaneous re-tracks can NACK (safe, everything rolls back; retry with a raised
    ///      budget or split, see the Stargate README, "UPDATE_VAULTS gas budget"). The tracked-set cap is asserted once after pass 2: tracked
    ///      vaults are then a subset of the allowlist (at most 32), so the check cannot fire in practice.
    ///      A vault whose `balanceOf` read fails (reverts, is malformed or needs more than `VAULT_READ_GAS`) is NOT
    ///      tracked again and nothing is emitted (the Stargate dispatcher emits no tracking events); the next
    ///      `UPDATE_VAULTS` after its `balanceOf` works again tracks it (IL-8849, D-073).
    /// @param allowed_ The dispatcher's allowlist array.
    /// @param isAllowed_ The dispatcher's allowlist flags.
    /// @param isTracked_ The dispatcher's tracked-set flags.
    /// @param tracked_ The dispatcher's tracked vault array.
    /// @return sweptAssetsLD The ASSET the sweeps put back into the dispatcher's balance, local decimals.
    function _reconcileTracked(
        address[] storage allowed_,
        mapping(address => bool) storage isAllowed_,
        mapping(address => bool) storage isTracked_,
        address[] storage tracked_
    ) private returns (uint256 sweptAssetsLD) {
        for (uint256 i; i < allowed_.length; ++i) {
            address vault = allowed_[i];
            if (isTracked_[vault]) continue;
            (bool ok, uint256 held) = TrackedVaultPricingLib.shares(vault, address(this));
            if (!ok || held == 0) continue;
            isTracked_[vault] = true;
            tracked_.push(vault);
        }
        for (uint256 i = tracked_.length; i > 0; --i) {
            address vault = tracked_[i - 1];
            if (isAllowed_[vault]) continue;
            (, uint256 assetsLD, , , ) = CrosschainVaultActionLib.sweepShares(vault);
            sweptAssetsLD += assetsLD;
            isTracked_[vault] = false;
            tracked_[i - 1] = tracked_[tracked_.length - 1];
            tracked_.pop();
        }
        if (tracked_.length > CrosschainConstants.MAX_TRACKED_POSITION_VAULTS) {
            revert CrosschainErrors.VaultsCapReached(CrosschainConstants.MAX_TRACKED_POSITION_VAULTS);
        }
    }

    /// @notice Removes a tracked vault from the tracked set and emits `TrackedVaultWrittenOff`.
    /// @dev The remaining share balance is recorded in the event only; the shares stay on the dispatcher.
    /// @param isTracked_ The dispatcher's tracked-set flags.
    /// @param tracked_ The dispatcher's tracked vault array.
    /// @param vault_ The vault to remove.
    function forceUntrack(
        mapping(address => bool) storage isTracked_,
        address[] storage tracked_,
        address vault_
    ) public {
        if (!isTracked_[vault_]) revert CrosschainErrors.VaultNotTracked(vault_);
        (, uint256 sharesLeft) = TrackedVaultPricingLib.shares(vault_, address(this));
        isTracked_[vault_] = false;
        uint256 len = tracked_.length;
        for (uint256 i; i < len; ++i) {
            if (tracked_[i] == vault_) {
                tracked_[i] = tracked_[len - 1];
                tracked_.pop();
                break;
            }
        }
        emit TrackedVaultWrittenOff(vault_, sharesLeft);
    }

    /// @notice `_afterRescueExecuted` body (IL-8640): after a generic rescue the ASSET balance must still cover
    ///         `min(balanceBefore_, trackedLD_)`, so a rescue removes only untracked surplus and never worsens an
    ///         already-underfunded ledger.
    /// @param asset_ The dispatcher's underlying asset.
    /// @param balanceBefore_ The ASSET balance before the rescue call.
    /// @param trackedLD_ The dispatcher's `trackedIdle` in local decimals.
    function checkRescueLedger(address asset_, uint256 balanceBefore_, uint256 trackedLD_) public view {
        uint256 balance = IERC20(asset_).balanceOf(address(this));
        uint256 tracked = balanceBefore_ < trackedLD_ ? balanceBefore_ : trackedLD_;
        if (balance < tracked) revert CrosschainErrors.RescueLedgerInvariantViolation(balance, tracked);
    }
}

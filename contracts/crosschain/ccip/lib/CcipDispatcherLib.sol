// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {CrosschainErrors} from "../../lib/CrosschainErrors.sol";
import {CrosschainVaultActionLib} from "../../lib/CrosschainVaultActionLib.sol";

/// @title CcipDispatcherLib
/// @notice Linked vault-set management for the CCIP dispatcher: allowlist/tracked-set configuration and the
///         best-effort sweep of vaults that leave the allowlist.
/// @dev This is an external linked library that keeps `CcipCrosschainDispatcher` below EIP-170. It runs through
///      delegatecall on the dispatcher's own storage: the vault mappings and the tracked array are passed by
///      storage reference, so every slot stays where the dispatcher declares it, and `address(this)` is the
///      dispatcher. The events are declared here because they are emitted from this library; their signatures
///      mirror the dispatcher's own declarations, so topics are identical.
///
///      Tracked set == allowlist (IL-8784, D-020 / D-028): a vault is tracked the moment it is allowlisted and,
///      when it leaves the allowlist, the library redeems its whole position into the dispatcher's idle balance
///      (`CrosschainVaultActionLib.sweepShares`) and ALWAYS untracks it, whatever the sweep left behind. A residual
///      is reported by `TrackedVaultSweepResidual` and drops out of NAV until the vault is allowlisted again, so
///      ALPHA must withdraw or recall a position BEFORE removing its vault.
library CcipDispatcherLib {
    event VaultAllowed(address vault, bool allowed);
    event VaultTracked(address vault);
    event VaultUntracked(address vault);

    /// @dev Must equal `CcipCrosschainDispatcher.MAX_TRACKED_VAULTS`.
    uint256 internal constant MAX_TRACKED_VAULTS = 32;

    /// @notice Adds or removes `vaults_` from the deposit allowlist, optionally replacing the whole allowlist.
    /// @dev Three passes. 1) Validate and flag: `replace_` first clears every allowlist flag, then each vault is
    ///      validated (code and underlying asset, only when ADDING so a vault that reverts on every call stays
    ///      removable) and flagged. 2) Sweep: every tracked vault that is no longer allowed is swept and untracked
    ///      (reverse iteration, because removal swap-and-pops). 3) Track: only now are the newly allowed vaults
    ///      tracked (cap-checked), so a replace at the 32-vault cap frees the slots of the vaults it removes
    ///      first (IL-8629).
    /// @param isAllowed_ The dispatcher's allowlist flags.
    /// @param isTracked_ The dispatcher's tracked-set flags.
    /// @param indexPlusOne_ The dispatcher's index-plus-one map into `tracked_`.
    /// @param tracked_ The dispatcher's tracked vault array.
    /// @param asset_ The dispatcher's underlying asset every allowlisted vault must share.
    /// @param vaults_ The vaults to add or remove.
    /// @param allowed_ True to allowlist `vaults_`, false to remove them.
    /// @param replace_ True to clear the existing allowlist before applying `vaults_`.
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
        bool replace_
    ) public returns (uint256 sweptAssetsLD) {
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
        if (!allowed_ || replace_) {
            for (uint256 i = tracked_.length; i > 0; --i) {
                address vault = tracked_[i - 1];
                if (isAllowed_[vault]) continue;
                (, uint256 assetsLD, , , ) = CrosschainVaultActionLib.sweepShares(vault);
                sweptAssetsLD += assetsLD;
                _removeTracked(isTracked_, indexPlusOne_, tracked_, vault);
            }
        }
        if (allowed_) {
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
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {BusinessAction, CrosschainConstants} from "../../lib/CrosschainConstants.sol";
import {CrosschainMessages, SweepFloor, UpdateVaults} from "../../lib/CrosschainMessages.sol";
import {CrosschainErrors} from "../../lib/CrosschainErrors.sol";
import {TrackedVaultPricingLib} from "../../lib/TrackedVaultPricingLib.sol";
import {IPlasmaVault} from "../../../interfaces/IPlasmaVault.sol";
import {CrosschainVaultActionLib} from "../../lib/CrosschainVaultActionLib.sol";

/// @notice Result of `StargateDispatcherLib.runBusinessAction`: the new tracked idle and, for REDEEM (`kind` 1) and
///         REDEEM_FROM_REQUEST (`kind` 2), what `finishRedeem` needs (`kind` 0 = nothing left to do).
struct BusinessOutcome {
    uint256 idle;
    uint8 kind;
    address vault;
    uint256 shares;
    uint256 deltaSD;
}

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
    event DepositExecuted(address vault, uint256 assetSpentSD, uint256 sharesDelta);
    event RedeemExecuted(address vault, uint256 sharesRedeemed, uint256 assetsDeltaSD);
    event RedeemedFromRequest(address vault, uint256 sharesRedeemed, uint256 assetsDeltaSD);

    /// @notice Applies a decoded `UPDATE_VAULTS`: replaces the deposit allowlist, then reconciles the tracked-position
    ///         set with it (IL-8784), and returns the ASSET the sweeps put back into the dispatcher.
    /// @dev IL-9629: the payload's `floors` set the sweep floor of each vault leaving the allowlist (shared decimals,
    ///      converted with `rate_`); the vaults retained below a floor by an earlier command are read before the
    ///      allowlist changes, so `_reconcileTracked` can leave them alone unless `floors` names them.
    ///      One linked call for both steps (EIP-170). The dispatcher stores `currentEpoch_ + 1` as its config epoch
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
    /// @param rate_ The dispatcher's shared-to-local decimal conversion rate (`_toLD(1)`).
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
        bytes calldata data_,
        uint256 rate_
    ) public returns (uint256 sweptAssetsLD) {
        UpdateVaults memory u = abi.decode(data_, (UpdateVaults));
        address[] memory retained = _retained(isAllowed_, tracked_);
        _replaceAllowlist(allowed_, isAllowed_, currentEpoch_, stateVersion_, asset_, u);
        sweptAssetsLD = _reconcileTracked(allowed_, isAllowed_, isTracked_, tracked_, retained, u.floors, rate_);
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
    /// @param u The decoded `UpdateVaults` payload.
    function _replaceAllowlist(
        address[] storage allowed_,
        mapping(address => bool) storage isAllowed_,
        uint64 currentEpoch_,
        uint64 stateVersion_,
        address asset_,
        UpdateVaults memory u
    ) private {
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
    ///      untracks every tracked vault that is no longer allowlisted, whatever the sweep left behind unless a
    ///      non-zero floor keeps it (below); a
    ///      residual is reported by `TrackedVaultSweepResidual` and stays outside NAV until the vault is allowlisted
    ///      again, so ALPHA must withdraw or recall a position BEFORE removing its vault. IL-9629: each sweep takes
    ///      the vault's `floors_` entry (no floor without one); a vault whose non-zero floor is not reached
    ///      (`SWEEP_BELOW_MIN`, nothing redeemed) or whose floored redeem reverts with error data and burns nothing
    ///      (IL-9694 D-002) STAYS TRACKED, off the allowlist and in NAV, and a vault in
    ///      `retained_` (retained so by an earlier command) is skipped unless `floors_` names it (a floor of 0 forces
    ///      the removal). ALPHA exits a retained position with a REDEEM, which untracks it once empty. This also frees
    ///      the slot of an emptied vault (IL-8644). Running the reads first means that after a gas-limited sweep only the
    ///      removal's own bookkeeping remains (well inside `VAULT_SWEEP_RESERVE_GAS`), so a burned sweep can no longer
    ///      starve the re-track reads. The allowlist replace and the re-track pass still run before the sweep and must
    ///      fit the command budget: measured on committed state, the 2,600,000 minimum lane carries one burned-sweep
    ///      removal with 31 kept vaults with a margin of about 168k at the 2,600,000 lane (edge measured at
    ///      2,429k–2,432k after IL-9629), and each newly tracked vault costs about 50k
    ///      of writes, so many simultaneous re-tracks can NACK (safe, everything rolls back; retry with a raised
    ///      budget or split, see the Stargate README, "UPDATE_VAULTS gas budget"). The tracked-set cap is asserted once after pass 2: tracked
    ///      vaults are then a subset of the allowlist (at most 32) plus the retained vaults, so the check fires only
    ///      when retained positions and allowlisted positions together exceed the cap (IL-9629): the command NACKs and
    ///      everything rolls back; redeem or force-remove a retained position first.
    ///      A vault whose `balanceOf` read fails (reverts, is malformed or needs more than `VAULT_READ_GAS`) is NOT
    ///      tracked again and nothing is emitted (the Stargate dispatcher emits no tracking events); the next
    ///      `UPDATE_VAULTS` after its `balanceOf` works again tracks it (IL-8849, D-073).
    /// @param allowed_ The dispatcher's allowlist array.
    /// @param isAllowed_ The dispatcher's allowlist flags.
    /// @param isTracked_ The dispatcher's tracked-set flags.
    /// @param tracked_ The dispatcher's tracked vault array.
    /// @param retained_ The vaults retained below a floor before this command (`_retained`).
    /// @param floors_ The command's sweep floors, shared decimals.
    /// @param rate_ The shared-to-local decimal conversion rate.
    /// @return sweptAssetsLD The ASSET the sweeps put back into the dispatcher's balance, local decimals.
    function _reconcileTracked(
        address[] storage allowed_,
        mapping(address => bool) storage isAllowed_,
        mapping(address => bool) storage isTracked_,
        address[] storage tracked_,
        address[] memory retained_,
        SweepFloor[] memory floors_,
        uint256 rate_
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
            (bool skip, uint256 minAssetsSD) = CrosschainMessages.sweepFloorFor(floors_, retained_, vault);
            if (skip) continue;
            // A floor above `type(uint256).max / rate_` can never be met: saturate it (reason 6, vault kept) instead of
            // letting the checked multiply panic and NACK the whole command.
            (uint256 assetsLD, bool keep) = _sweep(
                vault,
                minAssetsSD > type(uint256).max / rate_ ? type(uint256).max : minAssetsSD * rate_
            );
            sweptAssetsLD += assetsLD;
            if (keep) continue;
            isTracked_[vault] = false;
            tracked_[i - 1] = tracked_[tracked_.length - 1];
            tracked_.pop();
        }
        if (tracked_.length > CrosschainConstants.MAX_TRACKED_POSITION_VAULTS) {
            revert CrosschainErrors.VaultsCapReached(CrosschainConstants.MAX_TRACKED_POSITION_VAULTS);
        }
    }

    /// @dev One sweep (IL-9629): `keep` is true when the floor was not reached and the vault stays tracked.
    function _sweep(address vault_, uint256 minAssetsLD_) private returns (uint256 assetsLD, bool keep) {
        uint8 reason;
        (, assetsLD, , reason, ) = CrosschainVaultActionLib.sweepShares(vault_, minAssetsLD_);
        keep = reason == CrosschainVaultActionLib.SWEEP_BELOW_MIN;
    }

    /// @dev The tracked vaults that are off the allowlist when a command starts: retained below a floor by an earlier
    ///      command (IL-9629; every other path keeps the tracked set inside the allowlist: deposits track allowlisted
    ///      vaults only, a REDEEM that empties a vault untracks it). Allowlisted vaults are left as zero padding.
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

    /// @notice Runs a DEPOSIT, REDEEM or REDEEM_FROM_REQUEST business action (bodies of the dispatcher's former
    ///         `_deposit`, `_redeem`, `_redeemFromRequest`, `_creditRedeemed`, `_addTrackedVault`, `_maybeUntrack`
    ///         and `_assertVaultAsset`, moved here for EIP-170).
    /// @dev Runs through delegatecall, so `address(this)` is the dispatcher and `msg.sender` of the vault calls is
    ///      the dispatcher. Checks, external calls and storage writes keep the order of the former private bodies.
    ///      Any other `action_` reverts `UnexpectedMessageType`; REQUEST_SHARES is handled by the dispatcher.
    /// @param isAllowed_ The dispatcher's allowlist flags.
    /// @param isTracked_ The dispatcher's tracked-set flags.
    /// @param tracked_ The dispatcher's tracked vault array.
    /// @param trackedIdle_ The dispatcher's tracked idle ASSET (shared decimals) before the action.
    /// @param asset_ The dispatcher's underlying asset.
    /// @param rate_ The dispatcher's shared-to-local decimal conversion rate.
    /// @param action_ The business action id.
    /// @param actionData_ The ABI-encoded action payload.
    /// @return out The dispatcher's new tracked idle ASSET (`out.idle`, shared decimals), which the caller must store
    ///         right away, then, when `out.kind != 0`, call `finishRedeem` with the rest. This keeps the former order of
    ///         effects: `trackedIdle` is written before the untrack check's `balanceOf`, and the untrack and the event
    ///         come after it.
    function runBusinessAction(
        mapping(address => bool) storage isAllowed_,
        mapping(address => bool) storage isTracked_,
        address[] storage tracked_,
        uint256 trackedIdle_,
        address asset_,
        uint256 rate_,
        uint8 action_,
        bytes memory actionData_
    ) public returns (BusinessOutcome memory out) {
        if (action_ == uint8(BusinessAction.DEPOSIT)) {
            out.idle = _deposit(isAllowed_, isTracked_, tracked_, trackedIdle_, asset_, rate_, actionData_);
        } else if (action_ == uint8(BusinessAction.REDEEM)) {
            out.kind = 1;
            (out.vault, out.shares, out.deltaSD) = _redeem(isTracked_, asset_, rate_, actionData_);
            out.idle = trackedIdle_ + out.deltaSD;
        } else if (action_ == uint8(BusinessAction.REDEEM_FROM_REQUEST)) {
            out.kind = 2;
            (out.vault, out.shares, out.deltaSD) = _redeemFromRequest(isTracked_, asset_, rate_, actionData_);
            out.idle = trackedIdle_ + out.deltaSD;
        } else {
            revert CrosschainErrors.UnexpectedMessageType(action_);
        }
    }

    /// @notice Second half of REDEEM / REDEEM_FROM_REQUEST, run after the dispatcher stored `trackedIdle`: untracks the
    ///         vault if it is now empty (a request cannot be exercised without shares), then emits the event.
    /// @param isTracked_ The dispatcher's tracked-set flags.
    /// @param tracked_ The dispatcher's tracked vault array.
    /// @param kind_ 1 = REDEEM, 2 = REDEEM_FROM_REQUEST (`BusinessOutcome.kind`).
    /// @param vault_ The redeemed vault.
    /// @param shares_ The shares redeemed.
    /// @param deltaSD_ The credited asset delta, shared decimals.
    function finishRedeem(
        mapping(address => bool) storage isTracked_,
        address[] storage tracked_,
        uint8 kind_,
        address vault_,
        uint256 shares_,
        uint256 deltaSD_
    ) public {
        _maybeUntrack(isTracked_, tracked_, vault_);
        if (kind_ == 1) emit RedeemExecuted(vault_, shares_, deltaSD_);
        else emit RedeemedFromRequest(vault_, shares_, deltaSD_);
    }

    function _redeem(
        mapping(address => bool) storage isTracked_,
        address asset_,
        uint256 rate_,
        bytes memory actionData_
    ) private returns (address vault, uint256 redeemShares, uint256 deltaSD) {
        uint256 shares;
        uint256 minAssets;
        (vault, shares, minAssets) = CrosschainMessages.decodeRedeemAction(actionData_);
        if (!isTracked_[vault]) revert CrosschainErrors.VaultNotTracked(vault);
        redeemShares = _min(shares, IERC20(vault).balanceOf(address(this)));
        if (redeemShares == 0) revert CrosschainErrors.ZeroAmount();
        uint256 assetBefore = IERC20(asset_).balanceOf(address(this));
        IERC4626(vault).redeem(redeemShares, address(this), address(this));
        deltaSD = _creditRedeemed(asset_, rate_, assetBefore, minAssets);
    }

    function _redeemFromRequest(
        mapping(address => bool) storage isTracked_,
        address asset_,
        uint256 rate_,
        bytes memory actionData_
    ) private returns (address plasmaVault, uint256 shares, uint256 deltaSD) {
        address wm;
        uint256 minAssets;
        address receiver;
        (wm, plasmaVault, shares, minAssets, receiver) = CrosschainMessages.decodeRedeemFromRequestAction(actionData_);
        if (receiver != address(this)) revert CrosschainErrors.ReceiverMustBeSelf(receiver);
        if (!isTracked_[plasmaVault]) revert CrosschainErrors.VaultNotTracked(plasmaVault);
        // Consistency check only: the vault executes the redeem against its own manager.
        CrosschainVaultActionLib.requireVaultWithdrawManager(plasmaVault, wm);
        // The request bound is enforced by the vault's WithdrawManager (`canWithdrawFromRequest`).
        uint256 assetBefore = IERC20(asset_).balanceOf(address(this));
        IPlasmaVault(plasmaVault).redeemFromRequest(shares, address(this), address(this));
        deltaSD = _creditRedeemed(asset_, rate_, assetBefore, minAssets);
    }

    function _deposit(
        mapping(address => bool) storage isAllowed_,
        mapping(address => bool) storage isTracked_,
        address[] storage tracked_,
        uint256 trackedIdle_,
        address asset_,
        uint256 rate_,
        bytes memory actionData_
    ) private returns (uint256) {
        (address vault, uint256 amountSD, uint256 minShares) = CrosschainMessages.decodeDepositAction(actionData_);
        if (!isAllowed_[vault]) revert CrosschainErrors.VaultNotAllowed(vault);
        // IL-8645: admission checked `asset()` once; an upgradeable vault can change it later. Re-assert before any
        // approval. Redeems are deliberately not gated so a drifted position can always be exited.
        address actual = IERC4626(vault).asset();
        if (actual != asset_) revert CrosschainErrors.VaultAssetDrifted(vault, actual);
        uint256 amountLD = _min(amountSD * rate_, trackedIdle_ * rate_);
        if (amountLD == 0) revert CrosschainErrors.ZeroAmount();

        (uint256 spentSD, uint256 sharesDelta) = _depositMeasured(asset_, rate_, vault, amountLD, minShares);
        // Add the vault to the tracked-position set on first live position (cap-checked before growth).
        if (!isTracked_[vault]) {
            if (tracked_.length >= CrosschainConstants.MAX_TRACKED_POSITION_VAULTS) {
                revert CrosschainErrors.VaultsCapReached(CrosschainConstants.MAX_TRACKED_POSITION_VAULTS);
            }
            isTracked_[vault] = true;
            tracked_.push(vault);
        }
        emit DepositExecuted(vault, spentSD, sharesDelta);
        // Cannot underflow: `spentSD <= amountLD / rate <= trackedIdle`.
        return trackedIdle_ - spentSD;
    }

    /// @dev Deposits `amountLD_` and returns the measured spend, rounded UP to shared decimals so truncation can never
    ///      leave `trackedIdle` claiming value the dispatcher no longer holds, and the measured shares minted.
    function _depositMeasured(
        address asset_,
        uint256 rate_,
        address vault_,
        uint256 amountLD_,
        uint256 minShares_
    ) private returns (uint256 spentSD, uint256 sharesDelta) {
        uint256 assetBefore = IERC20(asset_).balanceOf(address(this));
        sharesDelta = CrosschainVaultActionLib.depositScoped(asset_, vault_, amountLD_);
        uint256 assetSpent = assetBefore - IERC20(asset_).balanceOf(address(this));
        if (sharesDelta < minShares_) revert CrosschainErrors.InsufficientShares(sharesDelta, minShares_);
        spentSD = (assetSpent + rate_ - 1) / rate_;
    }

    /// @dev Measured asset delta since `assetBefore_`, checked against the wire floor, in shared decimals.
    function _creditRedeemed(
        address asset_,
        uint256 rate_,
        uint256 assetBefore_,
        uint256 minAssets_
    ) private view returns (uint256) {
        uint256 assetsDelta = IERC20(asset_).balanceOf(address(this)) - assetBefore_;
        uint256 minAssetsLD = minAssets_ * rate_; // IL-8609: wire floor is SD, receipts are LD
        if (assetsDelta < minAssetsLD) revert CrosschainErrors.InsufficientAssets(assetsDelta, minAssetsLD);
        return assetsDelta / rate_;
    }

    /// @dev Removes a vault from the tracked-position set only when its share balance is zero (a request cannot be
    ///      exercised without shares).
    function _maybeUntrack(
        mapping(address => bool) storage isTracked_,
        address[] storage tracked_,
        address vault_
    ) private {
        if (!isTracked_[vault_]) return;
        if (IERC20(vault_).balanceOf(address(this)) != 0) return;
        isTracked_[vault_] = false;
        uint256 len = tracked_.length;
        for (uint256 i; i < len; ++i) {
            if (tracked_[i] == vault_) {
                tracked_[i] = tracked_[len - 1];
                tracked_.pop();
                return;
            }
        }
    }

    function _min(uint256 a_, uint256 b_) private pure returns (uint256) {
        return a_ < b_ ? a_ : b_;
    }
}

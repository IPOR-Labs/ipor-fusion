// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PlasmaVaultLib} from "../../../libraries/PlasmaVaultLib.sol";

/// @notice Transaction-scoped markers used by recovery fuses and the cross-chain balance fuse.
/// @dev Fuses execute by delegatecall in PlasmaVault context. Recovery fuses mark the `(market, executor)` scope
///      they drive in transient storage; if live cross-chain NAV remains fail-closed after the recovery action, the
///      balance fuse serves the previously cached market value (single-executor market) or each marked executor's
///      booked balance (several executors, staleness reverts only, IL-8611) instead of reverting the whole recovery
///      transaction. Several executors can be marked in one transaction (IL-9655).
library CrosschainRecoveryLib {
    /// @dev Head of the transient set of marked recovery scopes: the number of distinct `(market, executor)` scopes
    ///      armed in this transaction. Zero means that no recovery action has been armed (`isRecoveryArmed`).
    bytes32 private constant _RECOVERY_SLOT = keccak256("ipor.fusion.crosschain.recovery.active");
    /// @dev Entries of the set: scope `i` (0-based, `i < tload(_RECOVERY_SLOT)`) is stored at
    ///      `uint256(_RECOVERY_SCOPES_SLOT) + i`.
    bytes32 private constant _RECOVERY_SCOPES_SLOT = keccak256("ipor.fusion.crosschain.recovery.scopes");
    bytes32 private constant _EXPOSURE_SLOT = keccak256("ipor.fusion.crosschain.exposure.active");
    /// @dev USD-WAD value that recovery fuses moved OUT of the crosschain market and INTO the vault's own
    ///      balance during this transaction. The balance fuse subtracts it from the cached market value,
    ///      otherwise the same assets are counted twice — once in the stale cache and once in
    ///      `IERC20(asset).balanceOf(vault)` — inflating share price and minting performance fee on a
    ///      phantom gain (audit H-1).
    bytes32 private constant _RECOVERED_USD_SLOT = keccak256("ipor.fusion.crosschain.recovered.usd");
    /// @dev Persisted crosschain market value (underlying units, `+1` so that an unset slot reads as 0)
    ///      observed when `_RECOVERED_USD_SLOT` was last (re)based. `recoveredUsd` is only a valid
    ///      correction for THAT snapshot of the cache — see the note on batch scoping below.
    bytes32 private constant _CACHE_SNAPSHOT_SLOT = keccak256("ipor.fusion.crosschain.recovery.cacheSnapshot");

    error RecoveryExposureBatchForbidden();

    /// @notice Flag the current batch as a recovery action and rebase the recovered-value accumulator.
    /// @dev Transient storage is TRANSACTION-scoped, but the cached market value `recoveredUsd` corrects
    ///      is refreshed and PERSISTED at the end of every `PlasmaVault.execute()` batch. Once that write
    ///      lands, the recovered value is already gone from the cache and must not be subtracted again —
    ///      several `execute()` calls in one transaction (an ALPHA Safe using MultiSend, for instance)
    ///      would otherwise subtract the first batch's recovery from every later batch too, understating
    ///      NAV and persisting the understated value (audit R-07 / stale_accounting_double_subtraction).
    ///
    ///      The batch boundary is the balance fuse's valuation of the market (`consumeRecoveredUsd`): once it
    ///      has valued the market, the accumulator and its snapshot are cleared, so the next recovery fuse
    ///      always rebases. A refresh that persists the SAME numeric value as before (for example live NAV
    ///      equal to the old cache after a claim) cannot be told apart by comparing cache values alone, which
    ///      is why equality of the snapshot is only a second check (IL-9114). Until the balance fuse values the
    ///      market (at the end of the batch, or mid-batch through `UpdateMarketsBalancesFuse`), several recovery
    ///      fuses keep accumulating as intended.
    /// @param marketId_ The CROSSCHAIN market whose cached value the balance fuse will correct.
    /// @param executor_ The executor this recovery action drives. The marker is scoped to it, so a
    ///        recovery on one transport cannot suppress a fail-closed revert of a sibling executor that no
    ///        recovery action in this transaction drives. Marking a second executor adds its scope and keeps
    ///        the first one (IL-9655); marking the same scope again changes nothing.
    function markRecovery(uint256 marketId_, address executor_) internal {
        if (isNewExposure()) revert RecoveryExposureBatchForbidden();

        uint256 snapshot = _currentCacheSnapshot(marketId_);
        bytes32 snapshotSlot = _marketSlot(_CACHE_SNAPSHOT_SLOT, marketId_);
        uint256 storedSnapshot;
        assembly {
            storedSnapshot := tload(snapshotSlot)
        }
        if (storedSnapshot != snapshot) {
            bytes32 recoveredSlot = _marketSlot(_RECOVERED_USD_SLOT, marketId_);
            assembly {
                tstore(snapshotSlot, snapshot)
                tstore(recoveredSlot, 0)
            }
        }

        _addRecoveryScope(_recoveryScope(marketId_, executor_));
    }

    /// @dev The marker stores the SCOPES it was armed for, not a bare `1`. The balance fuse checks the executor
    ///      whose `getBalance()` actually reverted against the marked scopes, so a recovery driven against one
    ///      executor can no longer swallow a fail-closed revert from a sibling executor the batch never touched —
    ///      nor from a different market (audit
    ///      `cross_transport_recovery_marker_suppresses_fail_closed_gate_and_discards_sibling_executor_nav`).
    ///      Every recovery action adds its own scope (IL-9655): until IL-9655 one slot held one scope and a second
    ///      `markRecovery` overwrote the first, so when every executor of a market was stale (for example after
    ///      an outage of attesters they share) no batch could repair them, separately or together. With several
    ///      executors in the market the balance fuse substitutes `getBalanceUnchecked()` only for a marked executor
    ///      and only when its `getBalance()` reverted with a STALENESS selector (IL-8611); a `ChainBlocked` marked
    ///      executor, or an executor whose `getBalanceUnchecked()` reverts `ChainBlocked`, keeps the batch
    ///      reverting (the books are known-inconsistent until the rescue completes). It sums the other executors
    ///      live, because it cannot decompose one market-wide cache per executor; an executor that fails closed
    ///      while not marked still reverts, the safe direction.
    function _recoveryScope(uint256 marketId_, address executor_) private pure returns (bytes32) {
        return keccak256(abi.encode(marketId_, executor_));
    }

    /// @dev Adds `scope_` to the transient set of marked scopes unless it is already there.
    ///      A set behind one counter, not a per-scope mapping: the counter in `_RECOVERY_SLOT` is the only
    ///      switch of the whole marker, so zeroing it drops every marked scope at once and a scope marked
    ///      earlier can never resurface (tests model a transaction boundary that way). The set holds one entry
    ///      per distinct executor driven by a recovery action in this transaction, so the linear scan is short.
    function _addRecoveryScope(bytes32 scope_) private {
        bytes32 headSlot = _RECOVERY_SLOT;
        uint256 count;
        assembly {
            count := tload(headSlot)
        }
        if (_isScopeMarked(scope_, count)) return;
        uint256 entrySlot;
        unchecked {
            entrySlot = uint256(_RECOVERY_SCOPES_SLOT) + count;
        }
        assembly {
            tstore(entrySlot, scope_)
            tstore(headSlot, add(count, 1))
        }
    }

    /// @dev True when `scope_` is one of the first `count_` entries of the transient set of marked scopes.
    function _isScopeMarked(bytes32 scope_, uint256 count_) private view returns (bool) {
        uint256 entrySlot = uint256(_RECOVERY_SCOPES_SLOT);
        bytes32 stored;
        for (uint256 i; i < count_; ) {
            assembly {
                stored := tload(entrySlot)
            }
            if (stored == scope_) return true;
            unchecked {
                ++i;
                ++entrySlot;
            }
        }
        return false;
    }

    /// @notice True when `recoveredUsd()` still describes value missing from the CURRENT persisted cache.
    /// @dev False once a NAV refresh has persisted a cache that already excludes the recovered value, and
    ///      false when no recovery fuse has rebased the accumulator in this transaction or the balance fuse
    ///      has consumed it (`consumeRecoveredUsd`). The snapshot comparison alone cannot see a refresh that
    ///      wrote the same number, so the consumption is the primary batch boundary (IL-9114). In all of these
    ///      cases the cached market value must be used as-is; subtracting a spent accumulator understates NAV.
    /// @param marketId_ The CROSSCHAIN market whose cached value is being corrected.
    function isRecoveredUsdApplicable(uint256 marketId_) internal view returns (bool) {
        bytes32 snapshotSlot = _marketSlot(_CACHE_SNAPSHOT_SLOT, marketId_);
        uint256 storedSnapshot;
        assembly {
            storedSnapshot := tload(snapshotSlot)
        }
        return storedSnapshot != 0 && storedSnapshot == _currentCacheSnapshot(marketId_);
    }

    /// @dev The snapshot and the recovered-USD accumulator are keyed by market: two markets with equal numeric
    ///      cache values must never share a rebase decision or an accumulator (IL-8595).
    function _marketSlot(bytes32 baseSlot_, uint256 marketId_) private pure returns (bytes32) {
        return keccak256(abi.encode(baseSlot_, marketId_));
    }

    /// @dev `+1` keeps a legitimately zero market value distinguishable from an unset transient slot.
    function _currentCacheSnapshot(uint256 marketId_) private view returns (uint256) {
        return PlasmaVaultLib.getTotalAssetsInMarket(marketId_) + 1;
    }

    function markNewExposure() internal {
        if (isRecoveryArmed()) revert RecoveryExposureBatchForbidden();
        bytes32 exposureSlot = _EXPOSURE_SLOT;
        assembly {
            tstore(exposureSlot, 1)
        }
    }

    function isNewExposure() internal view returns (bool active) {
        bytes32 slot = _EXPOSURE_SLOT;
        assembly {
            active := tload(slot)
        }
    }

    /// @notice Record USD-WAD value a recovery fuse pulled out of the crosschain market into the vault.
    /// @dev Accumulates across several recovery fuse calls in one batch, per market.
    function addRecoveredUsd(uint256 marketId_, uint256 valueUsd_) internal {
        if (valueUsd_ == 0) return;
        bytes32 slot = _marketSlot(_RECOVERED_USD_SLOT, marketId_);
        uint256 current;
        assembly {
            current := tload(slot)
        }
        uint256 updated = current + valueUsd_;
        assembly {
            tstore(slot, updated)
        }
    }

    /// @notice Close the recovery accumulator of market `marketId_` once the balance fuse has valued the market.
    /// @dev The balance fuse calls this after every valuation of the market (live sum or cached fallback).
    ///      The value a recovery fuse moved out is either already absent from the live sum or has just been
    ///      subtracted from the cache, and the result is persisted by the surrounding batch, so the accumulator
    ///      must not be applied again. Clearing the snapshot makes the next `markRecovery` always rebase, even
    ///      when the persisted cache value is numerically unchanged (IL-9114). When nothing armed the
    ///      accumulator in this transaction the snapshot is zero and the function writes nothing, so ordinary
    ///      read-only NAV calls (for example `UniversalReader.read` under `staticcall`) stay write-free.
    /// @param marketId_ The CROSSCHAIN market whose accumulator is closed.
    function consumeRecoveredUsd(uint256 marketId_) internal {
        bytes32 snapshotSlot = _marketSlot(_CACHE_SNAPSHOT_SLOT, marketId_);
        uint256 storedSnapshot;
        assembly {
            storedSnapshot := tload(snapshotSlot)
        }
        if (storedSnapshot == 0) return;
        bytes32 recoveredSlot = _marketSlot(_RECOVERED_USD_SLOT, marketId_);
        assembly {
            tstore(snapshotSlot, 0)
            tstore(recoveredSlot, 0)
        }
    }

    /// @notice USD-WAD value already moved from crosschain market `marketId_` into the vault this transaction.
    function recoveredUsd(uint256 marketId_) internal view returns (uint256 value) {
        bytes32 slot = _marketSlot(_RECOVERED_USD_SLOT, marketId_);
        assembly {
            value := tload(slot)
        }
    }

    /// @notice True when THIS transaction armed a recovery action against exactly this executor on this
    ///         market. False for an executor no recovery action drove, a different market, or an ordinary batch.
    /// @dev Several executors can be marked in one transaction (IL-9655); each answers for its own scope only.
    function isRecovery(uint256 marketId_, address executor_) internal view returns (bool) {
        bytes32 headSlot = _RECOVERY_SLOT;
        uint256 count;
        assembly {
            count := tload(headSlot)
        }
        return count != 0 && _isScopeMarked(_recoveryScope(marketId_, executor_), count);
    }

    /// @notice True when any recovery action has been armed in this transaction, whatever its scope.
    /// @dev Only for the mutual exclusion with `markNewExposure`, which is a batch-level property.
    ///      Fail-closed decisions MUST use the scoped `isRecovery(marketId, executor)` instead.
    function isRecoveryArmed() internal view returns (bool active) {
        bytes32 slot = _RECOVERY_SLOT;
        assembly {
            active := iszero(iszero(tload(slot)))
        }
    }
}

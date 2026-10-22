// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PlasmaVaultLib} from "../../../libraries/PlasmaVaultLib.sol";

/// @notice Transaction-scoped marker used by recovery fuses and the cross-chain balance fuse.
/// @dev Fuses execute by delegatecall in PlasmaVault context. Recovery fuses set this transient flag;
///      if live cross-chain NAV remains fail-closed after the recovery action, the balance fuse serves the
///      previously cached market value (single-executor market) or the marked executor's booked balance
///      (several executors, staleness reverts only, IL-8611) instead of reverting the whole recovery transaction.
library CrosschainRecoveryLib {
    bytes32 private constant _RECOVERY_SLOT = keccak256("ipor.fusion.crosschain.recovery.active");
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
    ///      The persisted cache is therefore the batch boundary: whenever it differs from the snapshot
    ///      taken when the accumulator was last rebased, a NAV refresh has happened in between and the
    ///      accumulator is reset. Within one batch the cache does not move, so several recovery fuses in
    ///      the same batch keep accumulating as intended.
    /// @param marketId_ The CROSSCHAIN market whose cached value the balance fuse will correct.
    /// @param executor_ The executor this recovery action drives. The marker is scoped to it, so a
    ///        recovery on one transport cannot suppress a sibling executor's fail-closed revert.
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

        bytes32 slot = _RECOVERY_SLOT;
        bytes32 scope = _recoveryScope(marketId_, executor_);
        assembly {
            tstore(slot, scope)
        }
    }

    /// @dev The marker stores the SCOPE it was armed for, not a bare `1`. The balance fuse compares the
    ///      stored scope against the executor whose `getBalance()` actually reverted, so a recovery driven
    ///      against one executor can no longer swallow a fail-closed revert from a sibling executor the
    ///      batch never touched — nor from a different market (audit
    ///      `cross_transport_recovery_marker_suppresses_fail_closed_gate_and_discards_sibling_executor_nav`).
    ///      One slot rather than a per-scope mapping: only ONE executor can be marked per transaction, a
    ///      second `markRecovery` overwriting the first. With several executors in the market the balance
    ///      fuse substitutes `getBalanceUnchecked()` only for the marked executor and only when its
    ///      `getBalance()` reverted with a STALENESS selector (IL-8611); a `ChainBlocked` marked executor, or an
    ///      executor whose `getBalanceUnchecked()` reverts `ChainBlocked`, keeps the batch reverting (the books
    ///      are known-inconsistent until the rescue completes). It sums the siblings live, because it cannot
    ///      decompose one market-wide cache per executor; a sibling that fails closed while not marked still
    ///      reverts, the safe direction.
    function _recoveryScope(uint256 marketId_, address executor_) private pure returns (bytes32) {
        return keccak256(abi.encode(marketId_, executor_));
    }

    /// @notice True when `recoveredUsd()` still describes value missing from the CURRENT persisted cache.
    /// @dev False once a NAV refresh has persisted a cache that already excludes the recovered value, and
    ///      false when no recovery fuse has rebased the accumulator in this transaction. In both cases the
    ///      cached market value must be used as-is; subtracting a spent accumulator understates NAV.
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

    /// @notice USD-WAD value already moved from crosschain market `marketId_` into the vault this transaction.
    function recoveredUsd(uint256 marketId_) internal view returns (uint256 value) {
        bytes32 slot = _marketSlot(_RECOVERED_USD_SLOT, marketId_);
        assembly {
            value := tload(slot)
        }
    }

    /// @notice True when THIS transaction armed a recovery action against exactly this executor on this
    ///         market. False for a sibling executor, a different market, or an ordinary batch.
    function isRecovery(uint256 marketId_, address executor_) internal view returns (bool) {
        bytes32 slot = _RECOVERY_SLOT;
        bytes32 stored;
        assembly {
            stored := tload(slot)
        }
        return stored != bytes32(0) && stored == _recoveryScope(marketId_, executor_);
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

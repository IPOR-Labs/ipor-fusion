// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Errors} from "../../libraries/errors/Errors.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "../../libraries/PlasmaVaultStorageLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IExtTermAuctionOfferLocker} from "./ext/IExtTermAuctionOfferLocker.sol";
import {IExtTermAuctionBidLocker} from "./ext/IExtTermAuctionBidLocker.sol";
import {TermFinancePendingOffersStorageLib} from "./lib/TermFinancePendingOffersStorageLib.sol";
import {TermFinancePendingBidsStorageLib} from "./lib/TermFinancePendingBidsStorageLib.sol";

/// @notice Data for compacting pending-offer and pending-bid storage for a servicer.
/// @param servicer Substrate key — TermRepoServicer proxy
/// @param offerIds Candidate offer ids to prune. If empty, ALL stored offer ids for this servicer are inspected.
/// @param bidIds Candidate bid ids to prune. If empty, ALL stored bid ids for this servicer are inspected.
/// @param pruneOnLockerRevert Opt-in. When FALSE (the safe default), an entry whose
///        locker read REVERTS is left in place (only a `...SkippedOnRevert` diagnostic is
///        emitted) — a transient locker pause must not permanently erase a still-live offer/bid
///        from NAV. Set TRUE only to force-prune entries the operator has confirmed are dead
///        (e.g. a permanently-broken locker proxy), accepting that a paused-but-live entry
///        would be removed. Entries with `amount == 0` (genuinely cleared/cancelled) are pruned
///        regardless of this flag.
struct TermFinanceCleanupFuseEnterData {
    address servicer;
    bytes32[] offerIds;
    bytes32[] bidIds;
    bool pruneOnLockerRevert;
}

/// @title TermFinanceCleanupFuse
/// @author IPOR Labs
/// @notice Compact `TermFinancePendingOffersStorageLib` AND `TermFinancePendingBidsStorageLib`
///         by removing entries whose on-chain locker state indicates the entry is stale
///         (cleared, refunded, cancelled by the auction, or unrecoverable due to a broken /
///         upgraded locker proxy).
/// @dev `TermFinanceBalanceFuse.balanceOf` skips stale entries but does not write to storage
///      (it must stay staticcall-safe for ERC4626 preview paths). This fuse delegates the
///      storage write to an explicit ALPHA-gated action via `PlasmaVault.execute`.
///
///      Predicate semantics (canonical, mirrors BalanceFuse stale-skip):
///      - Offer side: prune iff `lockedOffer(id).amount == 0` (or the lookup reverts).
///      - Bid side: prune iff `lockedBid(id).bidder == address(0) || lockedBid(id).amount == 0`
///        (or the lookup reverts).
///
///      WithdrawManager check: `_assertWithdrawManagerSet()` runs as the FIRST statement of
///      `enter`. The CleanupFuse does not move funds, but the gate is included for consistency
///      with the rest of the Term Finance borrower fuse family (Bid / Collateral / Repurchase /
///      BidReveal); a missing WithdrawManager indicates a misconfigured vault and the cleanup
///      should not silently succeed in that state.
contract TermFinanceCleanupFuse is IFuseCommon {
    /// @notice Emitted once per successful `enter` call with a summary of how many entries were pruned.
    /// @param version Address of this fuse instance (also stored in `VERSION`).
    /// @param servicer TermRepoServicer proxy targeted by this cleanup call.
    /// @param offersRemoved Count of pending offers pruned during this call.
    /// @param bidsRemoved Count of pending bids pruned during this call.
    event TermFinanceCleanupExecuted(address version, address servicer, uint256 offersRemoved, uint256 bidsRemoved);

    /// @notice Emitted per-id when a pending offer entry is pruned because `lockedOffer(id)`
    ///         reverted (paused / upgraded / otherwise broken locker). Off-chain monitors
    ///         should treat this as a signal to investigate the underlying locker state
    ///         before assuming the pruned entry was genuinely cleared.
    event TermFinanceCleanupPrunedOnRevert(address version, address servicer, bytes32 offerId);

    /// @notice Emitted per-id when a pending bid entry is pruned because `lockedBid(id)`
    ///         reverted. Mirror of `TermFinanceCleanupPrunedOnRevert`; same operational
    ///         meaning for the bid (borrower) side.
    event TermFinanceCleanupPrunedBidOnRevert(address version, address servicer, bytes32 bidId);

    /// @notice Emitted per-id when a pending OFFER entry was NOT pruned because `lockedOffer(id)`
    ///         reverted and `pruneOnLockerRevert == false`. The entry is kept (a
    ///         transient locker pause must not erase a live offer from NAV); off-chain monitors
    ///         should investigate the locker and re-run cleanup with `pruneOnLockerRevert = true`
    ///         once the auction is confirmed dead.
    event TermFinanceCleanupSkippedOnRevert(address version, address servicer, bytes32 offerId);

    /// @notice Emitted per-id when a pending BID entry was NOT pruned because `lockedBid(id)`
    ///         reverted and `pruneOnLockerRevert == false`. Mirror of
    ///         `TermFinanceCleanupSkippedOnRevert` for the bid (borrower) side.
    event TermFinanceCleanupSkippedBidOnRevert(address version, address servicer, bytes32 bidId);

    /// @notice Reverts when `servicer` is not in the vault substrate allowlist.
    error TermFinanceCleanupFuseUnsupportedMarket(address servicer);

    /// @notice Reverts when the vault has no WithdrawManager configured (delegatecall-time check).
    error TermFinanceCleanupFuseWithdrawManagerRequired();

    /// @notice Address of this contract instance, used as the version identifier in event logs.
    address public immutable VERSION;
    /// @notice PlasmaVault market id assigned to Term Finance.
    uint256 public immutable MARKET_ID;

    /// @notice Initialise immutables.
    /// @param marketId_ PlasmaVault market id
    constructor(uint256 marketId_) {
        if (marketId_ == 0) revert Errors.WrongValue();

        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Compact pending-offer and pending-bid storage for `data_.servicer`.
    /// @dev Execution order:
    ///   0. `_assertWithdrawManagerSet()` — non-negotiable runtime invariant.
    ///   1. Substrate allowlist check on `data_.servicer`.
    ///   2. Offer cleanup leg — either targeted (`data_.offerIds` non-empty) or full-sweep.
    ///   3. Bid cleanup leg — either targeted (`data_.bidIds` non-empty) or full-sweep.
    ///   4. Emit aggregate `TermFinanceCleanupExecuted` with both counts.
    /// @param data_ See `TermFinanceCleanupFuseEnterData`.
    function enter(TermFinanceCleanupFuseEnterData calldata data_) external {
        _assertWithdrawManagerSet();

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.servicer)) {
            revert TermFinanceCleanupFuseUnsupportedMarket(data_.servicer);
        }

        uint256 offersRemoved = _cleanupOffers(data_.servicer, data_.offerIds, data_.pruneOnLockerRevert);
        uint256 bidsRemoved = _cleanupBids(data_.servicer, data_.bidIds, data_.pruneOnLockerRevert);

        emit TermFinanceCleanupExecuted(VERSION, data_.servicer, offersRemoved, bidsRemoved);
    }

    /// @notice Run the offer cleanup leg.
    /// @dev If `candidateIds_` is empty, snapshot the stored offer ids for `servicer_` and
    ///      sweep all of them; otherwise prune only the entries the caller asked for.
    /// @param servicer_ TermRepoServicer proxy.
    /// @param candidateIds_ Optional caller-supplied subset of offer ids to inspect.
    /// @return removed Number of offer entries pruned.
    function _cleanupOffers(
        address servicer_,
        bytes32[] calldata candidateIds_,
        bool pruneOnRevert_
    ) internal returns (uint256 removed) {
        if (candidateIds_.length == 0) {
            (address[] memory storedLockers, bytes32[] memory storedIds, ) = TermFinancePendingOffersStorageLib
                .getPendingOffersForServicer(servicer_);

            if (storedIds.length == 0) return 0;

            removed = _pruneStoredOffers(servicer_, storedLockers, storedIds, pruneOnRevert_);
        } else {
            removed = _pruneSelectedOffers(servicer_, candidateIds_, pruneOnRevert_);
        }
    }

    /// @notice Run the bid cleanup leg.
    /// @dev Snapshot-based iteration: we read `getPendingBidsForServicer` ONCE into memory
    ///      (or use the caller-supplied subset), then iterate the snapshot while mutating
    ///      storage. This is the canonical Solidity pattern for prune-during-iteration and
    ///      avoids the swap-and-pop reorder pitfall that `removePendingBidIfExists` performs.
    /// @param servicer_ TermRepoServicer proxy.
    /// @param candidateIds_ Optional caller-supplied subset of bid ids to inspect.
    /// @return removed Number of bid entries pruned.
    function _cleanupBids(
        address servicer_,
        bytes32[] calldata candidateIds_,
        bool pruneOnRevert_
    ) internal returns (uint256 removed) {
        if (candidateIds_.length == 0) {
            (address[] memory storedLockers, bytes32[] memory storedIds, , , ) = TermFinancePendingBidsStorageLib
                .getPendingBidsForServicer(servicer_);

            if (storedIds.length == 0) return 0;

            removed = _pruneStoredBids(servicer_, storedLockers, storedIds, pruneOnRevert_);
        } else {
            removed = _pruneSelectedBids(servicer_, candidateIds_, pruneOnRevert_);
        }
    }

    function _pruneStoredOffers(
        address servicer_,
        address[] memory storedLockers_,
        bytes32[] memory storedIds_,
        bool pruneOnRevert_
    ) internal returns (uint256 removed) {
        uint256 n = storedIds_.length;
        for (uint256 i; i < n; ++i) {
            address locker = storedLockers_[i];
            if (locker == address(0)) {
                // Defensive: an entry without a bound locker is unrecoverable (there is no
                // locker to un-pause) — prune it unconditionally.
                TermFinancePendingOffersStorageLib.removePendingOfferIfExists(servicer_, storedIds_[i]);
                emit TermFinanceCleanupPrunedOnRevert(VERSION, servicer_, storedIds_[i]);
                ++removed;
                continue;
            }
            if (_pruneOfferIfStale(servicer_, locker, storedIds_[i], pruneOnRevert_)) ++removed;
        }
    }

    function _pruneSelectedOffers(
        address servicer_,
        bytes32[] calldata candidateIds_,
        bool pruneOnRevert_
    ) internal returns (uint256 removed) {
        uint256 n = candidateIds_.length;
        for (uint256 i; i < n; ++i) {
            bytes32 id = candidateIds_[i];
            address locker = TermFinancePendingOffersStorageLib.getOfferLocker(servicer_, id);
            if (locker == address(0)) continue; // not tracked
            if (_pruneOfferIfStale(servicer_, locker, id, pruneOnRevert_)) ++removed;
        }
    }

    /// @notice Shared offer prune decision. Returns true iff the entry was removed.
    /// @dev Genuinely-stale (`amount == 0`) entries are always pruned. An entry whose locker
    ///      read REVERTS is pruned only when `pruneOnRevert_` is true; otherwise it is kept and
    ///      a `TermFinanceCleanupSkippedOnRevert` diagnostic is emitted so a transient locker
    ///      pause cannot silently erase a live offer from NAV.
    function _pruneOfferIfStale(
        address servicer_,
        address locker_,
        bytes32 id_,
        bool pruneOnRevert_
    ) private returns (bool) {
        (bool stale, bool onRevert) = _shouldPruneOffer(locker_, id_);
        if (stale || (onRevert && pruneOnRevert_)) {
            TermFinancePendingOffersStorageLib.removePendingOfferIfExists(servicer_, id_);
            if (onRevert) emit TermFinanceCleanupPrunedOnRevert(VERSION, servicer_, id_);
            return true;
        }
        if (onRevert) emit TermFinanceCleanupSkippedOnRevert(VERSION, servicer_, id_);
        return false;
    }

    function _pruneStoredBids(
        address servicer_,
        address[] memory storedLockers_,
        bytes32[] memory storedIds_,
        bool pruneOnRevert_
    ) internal returns (uint256 removed) {
        uint256 n = storedIds_.length;
        for (uint256 i; i < n; ++i) {
            address locker = storedLockers_[i];
            if (locker == address(0)) {
                // Defensive: an entry without a bound locker is unrecoverable (there is no
                // locker to un-pause) — prune it unconditionally.
                TermFinancePendingBidsStorageLib.removePendingBidIfExists(servicer_, storedIds_[i]);
                emit TermFinanceCleanupPrunedBidOnRevert(VERSION, servicer_, storedIds_[i]);
                ++removed;
                continue;
            }
            if (_pruneBidIfStale(servicer_, locker, storedIds_[i], pruneOnRevert_)) ++removed;
        }
    }

    function _pruneSelectedBids(
        address servicer_,
        bytes32[] calldata candidateIds_,
        bool pruneOnRevert_
    ) internal returns (uint256 removed) {
        uint256 n = candidateIds_.length;
        for (uint256 i; i < n; ++i) {
            bytes32 id = candidateIds_[i];
            address locker = TermFinancePendingBidsStorageLib.getBidLocker(servicer_, id);
            if (locker == address(0)) continue; // not tracked
            if (_pruneBidIfStale(servicer_, locker, id, pruneOnRevert_)) ++removed;
        }
    }

    /// @notice Shared bid prune decision. Mirror of `_pruneOfferIfStale`.
    function _pruneBidIfStale(
        address servicer_,
        address locker_,
        bytes32 id_,
        bool pruneOnRevert_
    ) private returns (bool) {
        (bool stale, bool onRevert) = _shouldPruneBid(locker_, id_);
        if (stale || (onRevert && pruneOnRevert_)) {
            TermFinancePendingBidsStorageLib.removePendingBidIfExists(servicer_, id_);
            if (onRevert) emit TermFinanceCleanupPrunedBidOnRevert(VERSION, servicer_, id_);
            return true;
        }
        if (onRevert) emit TermFinanceCleanupSkippedBidOnRevert(VERSION, servicer_, id_);
        return false;
    }

    /// @notice Canonical offer-side stale predicate.
    /// @dev Returns `(stale, onRevert)`. `stale == true` means the entry is PROVABLY stale on
    ///      chain (`amount == 0`) and is always safe to prune. `onRevert == true` means the
    ///      locker read REVERTED — the entry is NOT provably stale (the locker may simply be
    ///      paused), so the prune decision is deferred to the caller's `pruneOnLockerRevert`
    ///      opt-in. The two flags are mutually exclusive.
    function _shouldPruneOffer(
        address offerLocker_,
        bytes32 offerId_
    ) internal view returns (bool stale, bool onRevert) {
        try IExtTermAuctionOfferLocker(offerLocker_).lockedOffer(offerId_) returns (
            IExtTermAuctionOfferLocker.TermAuctionOffer memory offer
        ) {
            return (offer.amount == 0, false);
        } catch {
            // Locker reverted (paused / upgraded with incompatible ABI / proxy broken). This is
            // NOT proof the entry is dead — a transient pause reverts too. Do not mark it stale;
            // let the caller decide via `pruneOnLockerRevert`.
            return (false, true);
        }
    }

    /// @notice Canonical bid-side stale predicate (mirror of `_shouldPruneOffer`).
    /// @dev A bid is stale iff `bidder == address(0)` OR
    ///      `amount == 0`. Per the verified ABI of `lockedBid`, an unknown id returns a
    ///      zero-valued struct (NOT a revert); the try/catch is defensive against a future
    ///      BidLocker impl that decides to revert on unknown ids.
    /// @param bidLocker_ Bound TermAuctionBidLocker proxy.
    /// @param bidId_ Bid id to inspect.
    /// @return stale True iff the entry is PROVABLY stale on chain (`bidder == 0 || amount == 0`).
    /// @return onRevert True iff the locker call reverted (not proof of staleness).
    function _shouldPruneBid(address bidLocker_, bytes32 bidId_) internal view returns (bool stale, bool onRevert) {
        try IExtTermAuctionBidLocker(bidLocker_).lockedBid(bidId_) returns (
            IExtTermAuctionBidLocker.TermAuctionBid memory bid
        ) {
            return (bid.bidder == address(0) || bid.amount == 0, false);
        } catch {
            // Locker reverted (paused / upgraded with incompatible ABI / proxy broken). NOT
            // proof the entry is dead; defer the prune to the caller's `pruneOnLockerRevert`
            // opt-in. Mirror of the offer side.
            return (false, true);
        }
    }

    /// @notice Reverts unless the vault has a WithdrawManager configured.
    /// @dev Reads the canonical WITHDRAW_MANAGER storage slot via
    ///      `PlasmaVaultStorageLib.getWithdrawManager()`. During fuse delegatecall this slot
    ///      is read from PlasmaVault storage (the intended context). Included for consistency
    ///      with the rest of the Term Finance borrower fuse family.
    function _assertWithdrawManagerSet() private view {
        if (PlasmaVaultStorageLib.getWithdrawManager().manager == address(0)) {
            revert TermFinanceCleanupFuseWithdrawManagerRequired();
        }
    }
}

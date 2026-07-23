// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title TermFinancePendingOffersStorageLib
/// @notice ERC-7201 namespaced storage library for tracking pending Term Finance offers
///         (locked but not yet cleared/cancelled).
/// @dev Runs in PlasmaVault's delegatecall context. Tracks pending offer ids per servicer
///      so that `TermFinanceBalanceFuse` can include their value in `totalAssets()` and so
///      that `TermFinanceCleanupFuse` can compact stale entries after auction settlement.
library TermFinancePendingOffersStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.termFinance.PendingOffers")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TERM_FINANCE_PENDING_OFFERS_SLOT =
        0xb8f435ea456692e53dd82fb81b6d6633dd89cd6ba563993501ba7700172b4e00;

    /// @notice Hard cap on pending offers per servicer (anti-griefing).
    /// @dev Deliberately HIGHER than the bid side's `MAX_PENDING_BIDS_PER_SERVICER = 150`,
    ///      and intentionally NOT the upstream OfferLocker `MAX_OFFER_COUNT = 150`. The
    ///      upstream counter is PER-AUCTION and resets each cycle, whereas this storage
    ///      ACCUMULATES across auction cycles until `TermFinanceCleanupFuse` prunes cleared /
    ///      cancelled entries. 500 sizes the cap to several uncleaned lending cycles on one
    ///      servicer while staying well below the ~1.5-3k entry count at which
    ///      `TermFinanceBalanceFuse._sumLivePendingOffers` (one `lockedOffer` staticcall per
    ///      entry) would push `balanceOf` / `totalAssets` over the block gas limit and brick
    ///      the vault's ERC-4626 share math. Enforced by `TermFinanceOfferFuse.enter` BEFORE
    ///      the `forceApprove` / `lockOffers` call on any storage-growing path.
    uint256 internal constant MAX_PENDING_OFFERS_PER_SERVICER = 500;

    /// @notice Per-offer pending record.
    /// @dev `offerLocker` is stored PER OFFER (not per servicer) so that NAV stays correct
    ///      across Term Finance auction cycles: a single servicer can have offers from an
    ///      earlier auction's locker still live while a new auction's locker is used for
    ///      a fresh enter. Per-id binding eliminates the cross-cycle under-count.
    struct PendingOffer {
        /// @dev Offer id returned by TermAuctionOfferLocker.lockOffers
        bytes32 offerId;
        /// @dev TermAuctionOfferLocker that produced this offer id. Bound at lockOffers time
        ///      and stable for the life of the entry (entries are never re-bound to a different
        ///      locker; they are removed instead). NAV reads `lockedOffer` against this locker.
        address offerLocker;
        /// @dev Purchase-token amount locked at lockOffers time (raw units).
        uint256 amount;
    }

    /// @notice Per-servicer pending bookkeeping.
    /// @dev `indexOf` is 1-based: 0 == not present; (n+1) == position n in `offers`.
    struct ServicerOffers {
        PendingOffer[] offers;
        mapping(bytes32 offerId => uint256 indexPlusOne) indexOf;
    }

    /// @custom:storage-location erc7201:io.ipor.termFinance.PendingOffers
    struct PendingOffersStorage {
        address[] servicers;
        mapping(address servicer => uint256 indexPlusOne) servicerIndexOf;
        mapping(address servicer => ServicerOffers) byServicer;
    }

    function _getStorage() private pure returns (PendingOffersStorage storage s) {
        assembly {
            s.slot := TERM_FINANCE_PENDING_OFFERS_SLOT
        }
    }

    /// @notice Add a pending offer for a servicer.
    /// @dev If (servicer, offerId) is already tracked, refreshes BOTH the bound `offerLocker`
    ///      AND the `amount` so the latest enter call is reflected accurately in NAV (covers
    ///      the edit-flow which re-uses the same id with a different amount, and the rare
    ///      case where the same id is reassigned to a new locker on a fresh cycle).
    function addPendingOffer(address servicer_, address offerLocker_, bytes32 offerId_, uint256 amount_) internal {
        PendingOffersStorage storage s = _getStorage();
        ServicerOffers storage so = s.byServicer[servicer_];

        uint256 idxPlus = so.indexOf[offerId_];
        if (idxPlus != 0) {
            PendingOffer storage existing = so.offers[idxPlus - 1];
            existing.offerLocker = offerLocker_;
            existing.amount = amount_;
            return;
        }

        if (so.offers.length == 0) {
            // First entry for this servicer — add to top-level list.
            s.servicers.push(servicer_);
            s.servicerIndexOf[servicer_] = s.servicers.length;
        }

        so.offers.push(PendingOffer({offerId: offerId_, offerLocker: offerLocker_, amount: amount_}));
        so.indexOf[offerId_] = so.offers.length;
    }

    /// @notice Remove a pending offer if present. Idempotent — no revert if missing.
    /// @dev Returns `true` iff the entry was actually present and removed,
    ///      `false` if no matching `(servicer, offerId)` was tracked. Callers (notably
    ///      `TermFinanceOfferFuse.enter` on the edit-flow path) use the `removed` signal to
    ///      decide whether the operation is a true in-place refresh (length unchanged) or a
    ///      fresh insert that must still respect `MAX_PENDING_OFFERS_PER_SERVICER`. Without
    ///      the signal an attacker could pass a fake `existingOfferId` to bypass the cap.
    ///      Mirror of `TermFinancePendingBidsStorageLib.removePendingBidIfExists`.
    /// @param servicer_ TermRepoServicer proxy address.
    /// @param offerId_ Offer id to remove.
    /// @return removed True iff an entry with that `(servicer, offerId)` was tracked and
    ///         removed; false on idempotent no-op (entry not present).
    function removePendingOfferIfExists(address servicer_, bytes32 offerId_) internal returns (bool removed) {
        PendingOffersStorage storage s = _getStorage();
        ServicerOffers storage so = s.byServicer[servicer_];

        uint256 idxPlus = so.indexOf[offerId_];
        if (idxPlus == 0) return false;

        uint256 idx = idxPlus - 1;
        uint256 lastIdx = so.offers.length - 1;

        if (idx != lastIdx) {
            PendingOffer memory last = so.offers[lastIdx];
            so.offers[idx] = last;
            so.indexOf[last.offerId] = idx + 1;
        }

        so.offers.pop();
        delete so.indexOf[offerId_];

        if (so.offers.length == 0) {
            _removeServicer(s, servicer_);
        }
        return true;
    }

    /// @notice Read pending offers for a servicer, with the OfferLocker bound to each id at
    ///         lockOffers time.
    /// @return offerLockers Array of TermAuctionOfferLocker addresses (one per offerId)
    /// @return offerIds Array of pending offer ids
    /// @return amounts Array of pending amounts in purchase-token raw units (parallel to offerIds)
    function getPendingOffersForServicer(address servicer_)
        internal
        view
        returns (address[] memory offerLockers, bytes32[] memory offerIds, uint256[] memory amounts)
    {
        PendingOffersStorage storage s = _getStorage();
        ServicerOffers storage so = s.byServicer[servicer_];

        uint256 n = so.offers.length;
        offerLockers = new address[](n);
        offerIds = new bytes32[](n);
        amounts = new uint256[](n);

        for (uint256 i; i < n; ++i) {
            PendingOffer storage o = so.offers[i];
            offerLockers[i] = o.offerLocker;
            offerIds[i] = o.offerId;
            amounts[i] = o.amount;
        }
    }

    /// @notice Get the list of servicers with at least one pending offer.
    function getAllPendingServicers() internal view returns (address[] memory) {
        return _getStorage().servicers;
    }

    /// @notice Number of pending offers currently tracked for `servicer_`.
    /// @dev Mirrors `TermFinancePendingBidsStorageLib.length`. Consumed by
    ///      `TermFinanceBalanceFuse._hasTrackedExposure` so that the offers storage is
    ///      treated as tracked exposure on par with the bids storage.
    /// @param servicer_ TermRepoServicer proxy address.
    /// @return Pending offer count.
    function length(address servicer_) internal view returns (uint256) {
        return _getStorage().byServicer[servicer_].offers.length;
    }

    /// @notice Check whether a specific (servicer, offerId) is currently tracked.
    function isOfferPending(address servicer_, bytes32 offerId_) internal view returns (bool) {
        return _getStorage().byServicer[servicer_].indexOf[offerId_] != 0;
    }

    /// @notice Return the OfferLocker bound to a (servicer, offerId) entry at lockOffers time.
    /// @return offerLocker Bound locker address; `address(0)` if the entry is not tracked.
    function getOfferLocker(address servicer_, bytes32 offerId_) internal view returns (address offerLocker) {
        PendingOffersStorage storage s = _getStorage();
        ServicerOffers storage so = s.byServicer[servicer_];
        uint256 idxPlus = so.indexOf[offerId_];
        if (idxPlus == 0) return address(0);
        return so.offers[idxPlus - 1].offerLocker;
    }

    function _removeServicer(PendingOffersStorage storage s_, address servicer_) private {
        uint256 idxPlus = s_.servicerIndexOf[servicer_];
        // Defensive: unreachable from current callers. `_removeServicer` is only invoked at
        // the end of `removePendingOfferIfExists` after popping the last offer, which implies
        // the servicer was tracked (servicerIndexOf > 0). Kept as a belt-and-braces guard.
        if (idxPlus == 0) return;

        uint256 idx = idxPlus - 1;
        uint256 lastIdx = s_.servicers.length - 1;

        if (idx != lastIdx) {
            address lastServicer = s_.servicers[lastIdx];
            s_.servicers[idx] = lastServicer;
            s_.servicerIndexOf[lastServicer] = idx + 1;
        }

        s_.servicers.pop();
        delete s_.servicerIndexOf[servicer_];
    }
}

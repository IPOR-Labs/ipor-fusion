// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title TermFinancePendingBidsStorageLib
/// @author IPOR Labs
/// @notice ERC-7201 namespaced storage library for tracking pending Term Finance borrower
///         bids (locked but not yet cleared / cancelled).
/// @dev Runs in PlasmaVault's delegatecall context. Tracks pending bid ids per servicer so
///      that `TermFinanceBalanceFuse` can include the locked collateral USD value in
///      `totalAssets()` between `lockBids` and clearing, and so that `TermFinanceCleanupFuse`
///      can compact stale entries after auction settlement. Mirror of
///      `TermFinancePendingOffersStorageLib`; the per-bid record is intentionally wider —
///      it carries `(bidLocker, amount, collateralTokens, collateralAmounts)` because the
///      NAV value of a pending bid is the locked collateral, NOT the requested loan amount.
library TermFinancePendingBidsStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.termFinance.PendingBids")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TERM_FINANCE_PENDING_BIDS_SLOT =
        0x5990b0b45d7e06d831bc3297cd5581fbd1f0d7e2fad46b0a61ee842f66b79e00;

    /// @notice Hard cap on pending bids per servicer (anti-griefing).
    /// @dev Mirror of Term Finance BidLocker's own `MAX_BID_COUNT = 150` (verified on-chain
    ///      2026-05-15 against impl `0xEC2125566ee98761d0605E42B0c3b2adeB051007`). Enforced
    ///      by `TermFinanceBidFuse.enter` BEFORE the approval loop / `lockBids` call on the
    ///      non-edit path so a cap-breach reverts cheaply with no approval side
    ///      effects on the vault and no invocation of the external locker.
    uint256 internal constant MAX_PENDING_BIDS_PER_SERVICER = 150;

    /// @notice Per-bid pending record.
    /// @dev `bidLocker` is stored PER BID (not per servicer) so that NAV stays correct across
    ///      Term Finance auction cycles: a single servicer can have bids from an earlier
    ///      auction's locker still live while a new auction's locker is used for a fresh
    ///      enter. Per-id binding eliminates the cross-cycle under-count flagged by the
    ///      offers lib.
    /// @param bidId Bid id returned by `TermAuctionBidLocker.lockBids`.
    /// @param bidLocker `TermAuctionBidLocker` that produced this bid id (bound at lockBids
    ///        time and stable for the life of the entry; entries are never re-bound — they
    ///        are removed instead). NAV reads `lockedBid` against this locker.
    /// @param amount Purchase-token amount locked at lockBids time (raw units).
    /// @param collateralTokens Collateral tokens locked at lockBids time (parallel to
    ///        `collateralAmounts`). The NAV leg sums these via the IPOR oracle.
    /// @param collateralAmounts Collateral amounts locked at lockBids time (parallel to
    ///        `collateralTokens`; raw token units).
    struct PendingBid {
        bytes32 bidId;
        address bidLocker;
        uint256 amount;
        address[] collateralTokens;
        uint256[] collateralAmounts;
    }

    /// @notice Per-servicer pending-bid bookkeeping.
    /// @dev `indexOf` is 1-based: 0 == not present; (n+1) == position n in `bids`.
    struct ServicerBids {
        PendingBid[] bids;
        mapping(bytes32 bidId => uint256 indexPlusOne) indexOf;
    }

    /// @custom:storage-location erc7201:io.ipor.termFinance.PendingBids
    struct PendingBidsStorage {
        address[] servicers;
        mapping(address servicer => uint256 indexPlusOne) servicerIndexOf;
        mapping(address servicer => ServicerBids) byServicer;
    }


    /// @notice Add a pending bid for a servicer (or refresh an existing entry in-place).
    /// @dev If `(servicer_, bidId_)` is already tracked, refreshes the bound `bidLocker_`,
    ///      `amount_`, `collateralTokens_`, and `collateralAmounts_` so the latest enter call
    ///      is reflected accurately in NAV (covers the edit-flow which re-uses the same id
    ///      with a different amount / collateral mix).
    /// @param servicer_ TermRepoServicer proxy address.
    /// @param bidLocker_ TermAuctionBidLocker proxy address that produced the bid id.
    /// @param bidId_ Bid id returned by `lockBids`.
    /// @param amount_ Purchase-token amount in raw units.
    /// @param collateralTokens_ Collateral tokens locked (parallel to `collateralAmounts_`).
    /// @param collateralAmounts_ Collateral amounts locked (parallel to `collateralTokens_`).
    function addPendingBid(
        address servicer_,
        address bidLocker_,
        bytes32 bidId_,
        uint256 amount_,
        address[] memory collateralTokens_,
        uint256[] memory collateralAmounts_
    ) internal {
        PendingBidsStorage storage s = _getStorage();
        ServicerBids storage sb = s.byServicer[servicer_];

        uint256 idxPlus = sb.indexOf[bidId_];
        if (idxPlus != 0) {
            PendingBid storage existing = sb.bids[idxPlus - 1];
            existing.bidLocker = bidLocker_;
            existing.amount = amount_;
            existing.collateralTokens = collateralTokens_;
            existing.collateralAmounts = collateralAmounts_;
            return;
        }

        if (sb.bids.length == 0) {
            s.servicers.push(servicer_);
            s.servicerIndexOf[servicer_] = s.servicers.length;
        }

        sb.bids.push(
            PendingBid({
                bidId: bidId_,
                bidLocker: bidLocker_,
                amount: amount_,
                collateralTokens: collateralTokens_,
                collateralAmounts: collateralAmounts_
            })
        );
        sb.indexOf[bidId_] = sb.bids.length;
    }

    /// @notice Remove a pending bid if present. Idempotent — no revert if missing.
    /// @dev Returns `true` iff the entry was actually present and removed,
    ///      `false` if no matching `(servicer, bidId)` was tracked. Callers (notably
    ///      `TermFinanceBidFuse.enter` on the edit-flow path) use the `removed` signal to
    ///      decide whether the operation is a true in-place refresh (length unchanged) or
    ///      a fresh insert that must still respect `MAX_PENDING_BIDS_PER_SERVICER`. Without
    ///      the signal an attacker could pass a fake `existingBidId` to bypass the cap.
    /// @param servicer_ TermRepoServicer proxy address.
    /// @param bidId_ Bid id to remove.
    /// @return removed True iff an entry with that `(servicer, bidId)` was tracked and
    ///         removed; false on idempotent no-op (entry not present).
    function removePendingBidIfExists(address servicer_, bytes32 bidId_) internal returns (bool removed) {
        PendingBidsStorage storage s = _getStorage();
        ServicerBids storage sb = s.byServicer[servicer_];

        uint256 idxPlus = sb.indexOf[bidId_];
        if (idxPlus == 0) return false;

        uint256 idx = idxPlus - 1;
        uint256 lastIdx = sb.bids.length - 1;

        if (idx != lastIdx) {
            PendingBid memory last = sb.bids[lastIdx];
            sb.bids[idx] = last;
            sb.indexOf[last.bidId] = idx + 1;
        }

        sb.bids.pop();
        delete sb.indexOf[bidId_];

        if (sb.bids.length == 0) {
            _removeServicer(s, servicer_);
        }
        return true;
    }

    /// @notice Read all pending bids for a servicer.
    /// @dev Returns arrays parallel by index. The collateral arrays are returned as
    ///      arrays-of-arrays (per-bid collateral mix).
    /// @param servicer_ TermRepoServicer proxy address.
    /// @return bidLockers TermAuctionBidLocker addresses (one per bid).
    /// @return bidIds Pending bid ids.
    /// @return amounts Pending purchase-token amounts in raw units.
    /// @return collateralTokens Per-bid collateral token arrays (parallel to `bidIds`).
    /// @return collateralAmounts Per-bid collateral amount arrays (parallel to `bidIds`).
    function getPendingBidsForServicer(
        address servicer_
    )
        internal
        view
        returns (
            address[] memory bidLockers,
            bytes32[] memory bidIds,
            uint256[] memory amounts,
            address[][] memory collateralTokens,
            uint256[][] memory collateralAmounts
        )
    {
        PendingBidsStorage storage s = _getStorage();
        ServicerBids storage sb = s.byServicer[servicer_];

        uint256 n = sb.bids.length;
        bidLockers = new address[](n);
        bidIds = new bytes32[](n);
        amounts = new uint256[](n);
        collateralTokens = new address[][](n);
        collateralAmounts = new uint256[][](n);

        for (uint256 i; i < n; ++i) {
            PendingBid storage b = sb.bids[i];
            bidLockers[i] = b.bidLocker;
            bidIds[i] = b.bidId;
            amounts[i] = b.amount;
            collateralTokens[i] = b.collateralTokens;
            collateralAmounts[i] = b.collateralAmounts;
        }
    }

    /// @notice Get the list of servicers with at least one pending bid.
    /// @return Array of TermRepoServicer addresses tracked by the storage lib.
    function getAllPendingServicers() internal view returns (address[] memory) {
        return _getStorage().servicers;
    }

    /// @notice Number of pending bids currently tracked for `servicer_`.
    /// @dev Used by `TermFinanceBidFuse.enter` to enforce
    ///      `MAX_PENDING_BIDS_PER_SERVICER` after a fresh insert.
    /// @param servicer_ TermRepoServicer proxy address.
    /// @return Pending bid count.
    function length(address servicer_) internal view returns (uint256) {
        return _getStorage().byServicer[servicer_].bids.length;
    }

    /// @notice Check whether a specific `(servicer, bidId)` is currently tracked.
    /// @param servicer_ TermRepoServicer proxy address.
    /// @param bidId_ Bid id to look up.
    /// @return True if the entry is currently tracked.
    function isBidPending(address servicer_, bytes32 bidId_) internal view returns (bool) {
        return _getStorage().byServicer[servicer_].indexOf[bidId_] != 0;
    }

    /// @notice Return the bid locker bound to a `(servicer, bidId)` entry at lockBids time.
    /// @param servicer_ TermRepoServicer proxy address.
    /// @param bidId_ Bid id to look up.
    /// @return bidLocker Bound locker address; `address(0)` if the entry is not tracked.
    function getBidLocker(address servicer_, bytes32 bidId_) internal view returns (address bidLocker) {
        PendingBidsStorage storage s = _getStorage();
        ServicerBids storage sb = s.byServicer[servicer_];
        uint256 idxPlus = sb.indexOf[bidId_];
        if (idxPlus == 0) return address(0);
        return sb.bids[idxPlus - 1].bidLocker;
    }

    function _getStorage() private pure returns (PendingBidsStorage storage s) {
        assembly {
            s.slot := TERM_FINANCE_PENDING_BIDS_SLOT
        }
    }
    
    function _removeServicer(PendingBidsStorage storage s_, address servicer_) private {
        uint256 idxPlus = s_.servicerIndexOf[servicer_];
        // Defensive: unreachable from current callers. `_removeServicer` is only invoked at
        // the end of `removePendingBidIfExists` after popping the last bid, which implies
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

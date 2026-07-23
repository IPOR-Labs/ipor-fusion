// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IExtTermAuctionBidLocker} from "contracts/fuses/term_finance/ext/IExtTermAuctionBidLocker.sol";

/// @notice Minimal mock of `IExtTermAuctionBidLocker` for unit tests against
///         `TermFinanceBidFuse`. Mirrors `MockTermAuctionOfferLocker` for the borrower side.
/// @dev Stores bids; on `lockBids` assigns fresh ids when `id == 0x0` or reuses the supplied
///      id on the edit path. Reveal flips `isRevealed`. Unlock zeroes the entry.
///      `lockBidsReturnsEmpty` / `lockBidsReturnsExtra` exercise the
///      `TermFinanceBidFuseUnexpectedLockResult` guard.
contract MockTermAuctionBidLocker {
    address public termRepoServicer;
    address public purchaseToken;
    uint256 public auctionStartTime;
    uint256 public revealTime;
    uint256 public auctionEndTime;
    // solhint-disable-next-line const-name-snakecase
    uint256 public MAX_BID_PRICE = 100_000_000_000_000_000_000;
    // solhint-disable-next-line const-name-snakecase
    uint256 public MAX_BID_COUNT = 150;

    mapping(bytes32 => IExtTermAuctionBidLocker.TermAuctionBid) public bids;

    bool public lockedBidReverts;
    bool public lockBidsReverts;
    bool public revealBidsReverts;

    /// @dev Force `lockBids` to return an empty array (simulates a malicious/buggy locker proxy
    ///      ignoring submissions). Used by tests that exercise the length-guard.
    bool public lockBidsReturnsEmpty;
    /// @dev Force `lockBids` to return one extra trailing id (simulates a malicious locker
    ///      padding the response). Used by tests that exercise the length-guard.
    bool public lockBidsReturnsExtra;

    bytes32 public nextIdSeed = bytes32(uint256(0x1));

    /// @dev Number of times `lockBids` has been invoked on this mock. Used by tests that
    ///      assert pre-check ordering (e.g. cap-breach must short-circuit BEFORE the
    ///      external `lockBids` call).
    uint256 public lockBidsCallCount;

    function setTermRepoServicer(address v_) external {
        termRepoServicer = v_;
    }

    function setPurchaseToken(address v_) external {
        purchaseToken = v_;
    }

    function setAuctionStartTime(uint256 v_) external {
        auctionStartTime = v_;
    }

    function setRevealTime(uint256 v_) external {
        revealTime = v_;
    }

    function setAuctionEndTime(uint256 v_) external {
        auctionEndTime = v_;
    }

    function setLockedBidReverts(bool v_) external {
        lockedBidReverts = v_;
    }

    function setLockBidsReverts(bool v_) external {
        lockBidsReverts = v_;
    }

    function setRevealBidsReverts(bool v_) external {
        revealBidsReverts = v_;
    }

    function setLockBidsReturnsEmpty(bool v_) external {
        lockBidsReturnsEmpty = v_;
    }

    function setLockBidsReturnsExtra(bool v_) external {
        lockBidsReturnsExtra = v_;
    }

    /// @notice Force a specific bid record (helper for downstream tests).
    function setLockedBid(bytes32 id_, IExtTermAuctionBidLocker.TermAuctionBid memory bid_) external {
        bids[id_] = bid_;
    }

    function clearLockedBid(bytes32 id_) external {
        delete bids[id_];
    }

    function lockBids(
        IExtTermAuctionBidLocker.TermAuctionBidSubmission[] calldata submissions_
    ) external returns (bytes32[] memory ids) {
        ++lockBidsCallCount;
        if (lockBidsReverts) revert("MockBidLocker: lockBids reverts");

        if (lockBidsReturnsEmpty) {
            return new bytes32[](0);
        }
        if (lockBidsReturnsExtra) {
            ids = new bytes32[](submissions_.length + 1);
            for (uint256 j; j < submissions_.length; ++j) {
                ids[j] = submissions_[j].id == bytes32(0) ? _nextId() : submissions_[j].id;
            }
            ids[submissions_.length] = _nextId();
            return ids;
        }

        ids = new bytes32[](submissions_.length);
        for (uint256 i; i < submissions_.length; ++i) {
            IExtTermAuctionBidLocker.TermAuctionBidSubmission calldata s = submissions_[i];
            bytes32 id = s.id == bytes32(0) ? _nextId() : s.id;
            ids[i] = id;
            bids[id] = IExtTermAuctionBidLocker.TermAuctionBid({
                id: id,
                bidder: s.bidder,
                bidPriceHash: s.bidPriceHash,
                bidPriceRevealed: 0,
                amount: s.amount,
                collateralAmounts: s.collateralAmounts,
                purchaseToken: s.purchaseToken,
                collateralTokens: s.collateralTokens,
                isRollover: false,
                rolloverPairOffTermRepoServicer: address(0),
                isRevealed: false
            });
        }
    }

    function revealBids(
        bytes32[] calldata ids_,
        uint256[] calldata prices_,
        uint256[] calldata nonces_
    ) external {
        if (revealBidsReverts) revert("MockBidLocker: revealBids reverts");
        for (uint256 i; i < ids_.length; ++i) {
            IExtTermAuctionBidLocker.TermAuctionBid storage b = bids[ids_[i]];
            require(keccak256(abi.encode(prices_[i], nonces_[i])) == b.bidPriceHash, "hash mismatch");
            b.bidPriceRevealed = prices_[i];
            b.isRevealed = true;
        }
    }

    function unlockBids(bytes32[] calldata ids_) external {
        for (uint256 i; i < ids_.length; ++i) {
            delete bids[ids_[i]];
        }
    }

    function lockedBid(bytes32 id_) external view returns (IExtTermAuctionBidLocker.TermAuctionBid memory) {
        if (lockedBidReverts) revert("MockBidLocker: lockedBid reverts");
        return bids[id_];
    }

    function _nextId() internal returns (bytes32 id) {
        id = nextIdSeed;
        nextIdSeed = bytes32(uint256(nextIdSeed) + 1);
    }
}

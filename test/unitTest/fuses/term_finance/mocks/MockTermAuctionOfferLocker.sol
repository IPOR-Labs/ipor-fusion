// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IExtTermAuctionOfferLocker} from "contracts/fuses/term_finance/ext/IExtTermAuctionOfferLocker.sol";

/// @notice Minimal mock for unit tests. Stores offers; on lockOffers pulls funds via
///         `safeTransferFrom` (mimicking the `TermRepoLocker` pull) so the approve target
///         can be verified. Reveal updates `isRevealed`. Unlock returns funds.
contract MockTermAuctionOfferLocker {
    address public termRepoServicer;
    address public termRepoLocker; // approval target
    address public purchaseToken;
    uint256 public auctionStartTime;
    uint256 public revealTime;
    uint256 public auctionEndTime;
    // solhint-disable-next-line const-name-snakecase
    uint256 public MAX_OFFER_PRICE = 10_000e16;
    // solhint-disable-next-line const-name-snakecase
    uint256 public MAX_OFFER_COUNT = 150;

    mapping(bytes32 => IExtTermAuctionOfferLocker.TermAuctionOffer) public offers;

    bool public lockedOfferReverts;
    bool public lockOffersReverts;
    bool public revealOffersReverts;

    /// @dev Hook: force `lockOffers` to return an empty array (simulates a malicious/buggy
    ///      locker proxy ignoring submissions). Used by tests that exercise the length-guard.
    bool public lockOffersReturnsEmpty;
    /// @dev Hook: force `lockOffers` to return one extra trailing id (simulates a malicious
    ///      locker padding the response). Used by tests that exercise the length-guard.
    bool public lockOffersReturnsExtra;

    /// @dev If true, the mock actually pulls funds via `transferFrom(offeror, termRepoLocker)`
    ///      using whatever allowance was set. Off by default to preserve historical test semantics
    ///      (legacy tests assert the post-call allowance is 0; pulling funds zeroes it as a side effect).
    bool public pullFundsOnLock;

    bytes32 public nextIdSeed = bytes32(uint256(0x1));

    function setTermRepoServicer(address v_) external {
        termRepoServicer = v_;
    }

    function setTermRepoLocker(address v_) external {
        termRepoLocker = v_;
    }

    function setPurchaseToken(address v_) external {
        purchaseToken = v_;
    }

    function setLockedOfferReverts(bool v_) external {
        lockedOfferReverts = v_;
    }

    function setLockOffersReverts(bool v_) external {
        lockOffersReverts = v_;
    }

    function setRevealOffersReverts(bool v_) external {
        revealOffersReverts = v_;
    }

    function setLockOffersReturnsEmpty(bool v_) external {
        lockOffersReturnsEmpty = v_;
    }

    function setLockOffersReturnsExtra(bool v_) external {
        lockOffersReturnsExtra = v_;
    }

    function setPullFundsOnLock(bool v_) external {
        pullFundsOnLock = v_;
    }

    /// @notice Force a specific offer record (helper for balance fuse testing).
    function setLockedOffer(bytes32 id_, IExtTermAuctionOfferLocker.TermAuctionOffer memory offer_) external {
        offers[id_] = offer_;
    }

    function clearLockedOffer(bytes32 id_) external {
        delete offers[id_];
    }

    function lockOffers(
        IExtTermAuctionOfferLocker.TermAuctionOfferSubmission[] calldata submissions_
    ) external returns (bytes32[] memory ids) {
        if (lockOffersReverts) revert("MockOfferLocker: lockOffers reverts");

        // Hooks for length-guard tests in TermFinanceOfferFuse.enter:
        if (lockOffersReturnsEmpty) {
            return new bytes32[](0);
        }
        if (lockOffersReturnsExtra) {
            // Pretend to return one extra trailing id beyond the single submission. Doesn't write
            // to offers — just exercises the OfferFuse length check.
            ids = new bytes32[](submissions_.length + 1);
            for (uint256 j; j < submissions_.length; ++j) {
                ids[j] = submissions_[j].id == bytes32(0) ? _nextId() : submissions_[j].id;
            }
            ids[submissions_.length] = _nextId();
            return ids;
        }

        ids = new bytes32[](submissions_.length);
        for (uint256 i; i < submissions_.length; ++i) {
            IExtTermAuctionOfferLocker.TermAuctionOfferSubmission calldata s = submissions_[i];

            // Optionally pull funds for tests that want to verify TermRepoLocker pull
            // semantics end-to-end. Most legacy tests rely on the post-call allowance being 0
            // (set by `forceApprove(termRepoLocker, 0)` in the fuse), so the default is off.
            if (pullFundsOnLock && s.amount > 0 && purchaseToken != address(0) && termRepoLocker != address(0)) {
                IERC20(purchaseToken).transferFrom(s.offeror, termRepoLocker, s.amount);
            }
            // Approval target verification path: legacy tests assert
            // `allowance(offeror, termRepoLocker) == 0` after the call (the fuse resets it),
            // proving the approval went to the correct address.

            bytes32 id = s.id == bytes32(0) ? _nextId() : s.id;
            ids[i] = id;
            offers[id] = IExtTermAuctionOfferLocker.TermAuctionOffer({
                id: id,
                offeror: s.offeror,
                offerPriceHash: s.offerPriceHash,
                offerPriceRevealed: 0,
                amount: s.amount,
                purchaseToken: s.purchaseToken,
                isRevealed: false
            });
        }
    }

    function revealOffers(
        bytes32[] calldata ids_,
        uint256[] calldata prices_,
        uint256[] calldata nonces_
    ) external {
        if (revealOffersReverts) revert("MockOfferLocker: revealOffers reverts");
        for (uint256 i; i < ids_.length; ++i) {
            IExtTermAuctionOfferLocker.TermAuctionOffer storage o = offers[ids_[i]];
            require(keccak256(abi.encode(prices_[i], nonces_[i])) == o.offerPriceHash, "hash mismatch");
            o.offerPriceRevealed = prices_[i];
            o.isRevealed = true;
        }
    }

    function unlockOffers(bytes32[] calldata ids_) external {
        for (uint256 i; i < ids_.length; ++i) {
            delete offers[ids_[i]];
        }
    }

    function lockedOffer(bytes32 id_) external view returns (IExtTermAuctionOfferLocker.TermAuctionOffer memory) {
        if (lockedOfferReverts) revert("MockOfferLocker: lockedOffer reverts");
        return offers[id_];
    }

    function _nextId() internal returns (bytes32 id) {
        id = nextIdSeed;
        nextIdSeed = bytes32(uint256(nextIdSeed) + 1);
    }
}

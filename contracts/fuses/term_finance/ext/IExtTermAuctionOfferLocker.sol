// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title Extended interface for Term Finance TermAuctionOfferLocker
/// @notice Adds explicit declarations for view functions that exist on the concrete proxy
///         (e.g. termRepoServicer, auctionStartTime, revealTime) but are NOT declared in
///         the upstream interface.
/// @dev Field ORDER in TermAuctionOffer is load-bearing: (id, offeror, offerPriceHash,
///      offerPriceRevealed, amount, purchaseToken, isRevealed) — matches the concrete struct.
interface IExtTermAuctionOfferLocker {
    struct TermAuctionOfferSubmission {
        bytes32 id;
        address offeror;
        bytes32 offerPriceHash;
        uint256 amount;
        address purchaseToken;
    }

    struct TermAuctionOffer {
        bytes32 id;
        address offeror;
        bytes32 offerPriceHash;
        uint256 offerPriceRevealed;
        uint256 amount;
        address purchaseToken;
        bool isRevealed;
    }

    function lockOffers(TermAuctionOfferSubmission[] calldata offerSubmissions) external returns (bytes32[] memory);

    function revealOffers(
        bytes32[] calldata ids,
        uint256[] calldata prices,
        uint256[] calldata nonces
    ) external;

    function unlockOffers(bytes32[] calldata ids) external;

    function lockedOffer(bytes32 id) external view returns (TermAuctionOffer memory);

    function termRepoServicer() external view returns (address);

    function purchaseToken() external view returns (address);

    function auctionStartTime() external view returns (uint256);

    function revealTime() external view returns (uint256);

    function auctionEndTime() external view returns (uint256);

    // solhint-disable-next-line func-name-mixedcase
    function MAX_OFFER_PRICE() external view returns (uint256);

    // solhint-disable-next-line func-name-mixedcase
    function MAX_OFFER_COUNT() external view returns (uint256);
}

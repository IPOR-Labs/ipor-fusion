// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title Extended interface for Term Finance TermAuctionBidLocker
/// @notice Adds explicit declarations for view functions that exist on the concrete proxy
///         (e.g. termRepoServicer, auctionStartTime, revealTime) but are NOT declared in
///         the upstream interface.
/// @dev Field ORDER in TermAuctionBidSubmission and TermAuctionBid is load-bearing —
///      verified against impl 0xEC2125566ee98761d0605E42B0c3b2adeB051007 (v0.9.0) on
///      Ethereum mainnet on 2026-05-15. NOTE: collateralAmounts comes BEFORE purchaseToken
///      which comes BEFORE collateralTokens in BOTH structs. The two arrays are NOT adjacent
///      and the array-length parallelism is collateralAmounts[i] <-> collateralTokens[i].
interface IExtTermAuctionBidLocker {
    /// @notice Submission shape passed to lockBids (and lockBidsWithReferral).
    /// @dev VERIFIED FIELD ORDER (do not reorder):
    ///      id, bidder, bidPriceHash, amount, collateralAmounts, purchaseToken, collateralTokens.
    /// @param id 0x0 for new bid; non-zero to edit an existing bid.
    /// @param bidder Borrower address (PlasmaVault during fuse delegatecall).
    /// @param bidPriceHash keccak256(abi.encode(price, nonce)) — commit-phase rate hash.
    /// @param amount Purchase-token amount requested in raw units.
    /// @param collateralAmounts Parallel to `collateralTokens`; raw token units to lock.
    /// @param purchaseToken Purchase token of the Term Repo (loan token).
    /// @param collateralTokens Parallel to `collateralAmounts`; per-bid collateral tokens.
    struct TermAuctionBidSubmission {
        bytes32 id;
        address bidder;
        bytes32 bidPriceHash;
        uint256 amount;
        uint256[] collateralAmounts;
        address purchaseToken;
        address[] collateralTokens;
    }

    /// @notice Storage shape returned by `lockedBid`.
    /// @dev VERIFIED FIELD ORDER (do not reorder):
    ///      id, bidder, bidPriceHash, bidPriceRevealed, amount, collateralAmounts,
    ///      purchaseToken, collateralTokens, isRollover, rolloverPairOffTermRepoServicer,
    ///      isRevealed. Note: `isRevealed` is the LAST field, not adjacent to `isRollover`.
    /// @param id Bid identifier (zeroed on cancel / clearing).
    /// @param bidder Borrower address.
    /// @param bidPriceHash Commit-phase hash.
    /// @param bidPriceRevealed Plaintext price after reveal (zero pre-reveal).
    /// @param amount Purchase-token amount requested in raw units.
    /// @param collateralAmounts Parallel to `collateralTokens`.
    /// @param purchaseToken Purchase token of the Term Repo.
    /// @param collateralTokens Parallel to `collateralAmounts`.
    /// @param isRollover True for bids submitted via the rollover path.
    /// @param rolloverPairOffTermRepoServicer Paired prior-term servicer for rollover bids.
    /// @param isRevealed True after the bid has been revealed during the reveal window.
    struct TermAuctionBid {
        bytes32 id;
        address bidder;
        bytes32 bidPriceHash;
        uint256 bidPriceRevealed;
        uint256 amount;
        uint256[] collateralAmounts;
        address purchaseToken;
        address[] collateralTokens;
        bool isRollover;
        address rolloverPairOffTermRepoServicer;
        bool isRevealed;
    }

    /// @notice Commit a batch of sealed bids during the auction submission window.
    /// @param bidSubmissions Array of `TermAuctionBidSubmission` (see field order note).
    /// @return Array of assigned bid ids (parallel to `bidSubmissions`).
    function lockBids(TermAuctionBidSubmission[] calldata bidSubmissions) external returns (bytes32[] memory);

    /// @notice Reveal previously committed bids during the auction reveal window.
    /// @param ids Bid identifiers to reveal.
    /// @param prices Plaintext prices (parallel to `ids`).
    /// @param nonces Per-bid nonces used in `bidPriceHash` (parallel to `ids`).
    function revealBids(bytes32[] calldata ids, uint256[] calldata prices, uint256[] calldata nonces) external;

    /// @notice Cancel previously committed bids (pre-reveal only).
    /// @param ids Bid identifiers to cancel.
    function unlockBids(bytes32[] calldata ids) external;

    /// @notice Read the stored state of a bid.
    /// @dev Returns a zero-valued struct (NOT a revert) for unknown ids.
    /// @param id Bid identifier.
    /// @return Stored `TermAuctionBid` (all-zero if cancelled, cleared, or unknown).
    function lockedBid(bytes32 id) external view returns (TermAuctionBid memory);

    /// @notice Paired `TermRepoServicer` proxy for this auction.
    /// @return TermRepoServicer proxy address.
    function termRepoServicer() external view returns (address);

    /// @notice Purchase token of the Term Repo (loan token).
    /// @return Purchase token address.
    function purchaseToken() external view returns (address);

    /// @notice Auction submission window start timestamp (seconds since unix epoch).
    /// @return Unix timestamp.
    function auctionStartTime() external view returns (uint256);

    /// @notice Auction reveal window start timestamp (seconds since unix epoch).
    /// @dev Submission window ends at this time — no new `lockBids` accepted at or after
    ///      `revealTime`.
    /// @return Unix timestamp.
    function revealTime() external view returns (uint256);

    /// @notice Auction clearing window end timestamp (seconds since unix epoch).
    /// @return Unix timestamp.
    function auctionEndTime() external view returns (uint256);

    /// @notice Maximum allowed bid price (= maximum borrow rate accepted by the locker).
    /// @dev Verified value on Ethereum mainnet 2026-05-15: 100_000_000_000_000_000_000 (= 1e20).
    /// @return Maximum bid price in `RATE_PRECISION = 1e18` units.
    // solhint-disable-next-line func-name-mixedcase
    function MAX_BID_PRICE() external view returns (uint256);

    /// @notice Maximum number of bids accepted per `lockBids` submission.
    /// @dev Verified value on Ethereum mainnet 2026-05-15: 150.
    /// @return Maximum bid count.
    // solhint-disable-next-line func-name-mixedcase
    function MAX_BID_COUNT() external view returns (uint256);
}

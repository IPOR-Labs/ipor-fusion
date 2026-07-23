// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title Extended interface for Term Finance TermController
/// @notice Adds explicit declarations for view functions that exist on the concrete proxy
///         but are NOT declared in the upstream Term Finance contracts interfaces.
interface IExtTermController {
    struct AuctionMetadata {
        bytes32 termAuctionId;
        uint256 auctionClearingRate;
        uint256 auctionClearingBlockTimestamp;
    }

    function isTermDeployed(address contractAddress) external view returns (bool);

    function getTreasuryAddress() external view returns (address);

    function getProtocolReserveAddress() external view returns (address);

    function getTermAuctionResults(bytes32 termRepoId) external view returns (AuctionMetadata[] memory);
}

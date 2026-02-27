// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IMidasDataFeed
/// @notice Interface for Midas data feed providing mToken price information
interface IMidasDataFeed {
    /// @notice Get the price of mToken in USD (base 18)
    /// @return price The price in 18 decimals (1e18 = $1.00)
    function getDataInBase18() external view returns (uint256);
}

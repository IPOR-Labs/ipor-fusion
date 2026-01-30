// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.30;

/// @title IPriceOracleGetter
/// @notice Interface for the Aave V4 price oracle
/// @dev Returns asset prices in USD with 8 decimals (Chainlink standard)
interface IPriceOracleGetter {
    /// @notice Returns the asset price in the base currency (USD)
    /// @param asset The address of the asset
    /// @return The price of the asset in USD, represented with 8 decimals
    function getAssetPrice(address asset) external view returns (uint256);
}

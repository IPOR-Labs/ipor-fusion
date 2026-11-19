// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IPendleMarketFactory
/// @notice Minimal view of a Pendle market factory used to validate markets in the price oracle middleware
interface IPendleMarketFactory {
    /// @notice Returns true when the market was deployed by this factory
    /// @param market_ Address of the Pendle market to check
    function isValidMarket(address market_) external view returns (bool);
}

/// @title IPendleMarketWithFactory
/// @notice Minimal view of a Pendle market exposing the factory that created it (Pendle market V3 and later)
interface IPendleMarketWithFactory {
    /// @notice Returns the factory that deployed this market
    function factory() external view returns (address);
}

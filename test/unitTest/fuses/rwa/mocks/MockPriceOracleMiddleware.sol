// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @title MockPriceOracleMiddleware
/// @notice Minimal mock of `IPriceOracleMiddleware` used by RWA fuses unit tests.
///         Allows setting per-asset (price, decimals) and returns them from `getAssetPrice`.
contract MockPriceOracleMiddleware {
    struct PriceData {
        uint256 price;
        uint256 decimals;
        bool set;
    }

    mapping(address asset => PriceData data) public prices;

    /// @notice Set price data for an asset.
    function setPrice(address asset_, uint256 price_, uint256 decimals_) external {
        prices[asset_] = PriceData({price: price_, decimals: decimals_, set: true});
    }

    /// @notice Returns (price, decimals) for `asset_`. Reverts if unset so tests catch missing configuration.
    function getAssetPrice(address asset_) external view returns (uint256 price, uint256 decimals) {
        PriceData memory data = prices[asset_];
        require(data.set, "MockPriceOracleMiddleware: asset not configured");
        return (data.price, data.decimals);
    }
}

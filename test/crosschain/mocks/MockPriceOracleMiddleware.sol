// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @title MockPriceOracleMiddleware
/// @notice Minimal `IPriceOracleMiddleware`-shaped oracle exposing `getAssetPrice(asset)`. Prices and their
///         decimals are settable per asset so the balance fuse's USD-WAD conversion can be checked exactly.
contract MockPriceOracleMiddleware {
    mapping(address asset => uint256 price) public priceOf;
    mapping(address asset => uint256 decimals) public priceDecimalsOf;

    error UnsupportedAsset();

    function setPrice(address asset_, uint256 price_, uint256 decimals_) external {
        priceOf[asset_] = price_;
        priceDecimalsOf[asset_] = decimals_;
    }

    function getAssetPrice(address asset_) external view returns (uint256 price, uint256 decimals) {
        price = priceOf[asset_];
        if (price == 0) revert UnsupportedAsset();
        decimals = priceDecimalsOf[asset_];
    }
}

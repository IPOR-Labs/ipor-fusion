// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @notice Minimal mock for IPriceOracleMiddleware used in BalancerBalanceFuse unit tests.
///         Returns configurable (price, decimals) per asset address. Mirrors
///         test/unitTest/fuses/midas/mocks/MockPriceOracleMiddlewareForBalance.sol.
contract MockPriceOracleMiddlewareForBalance {
    struct PriceData {
        uint256 price;
        uint256 decimals;
    }

    mapping(address => PriceData) private _prices;

    function setAssetPrice(address asset_, uint256 price_, uint256 decimals_) external {
        _prices[asset_] = PriceData({price: price_, decimals: decimals_});
    }

    function getAssetPrice(address asset_) external view returns (uint256 assetPrice, uint256 decimals) {
        PriceData storage data = _prices[asset_];
        return (data.price, data.decimals);
    }
}

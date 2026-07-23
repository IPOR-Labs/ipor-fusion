// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

contract MockPriceOracleMiddlewareForTermFinance {
    struct PriceData {
        uint256 price;
        uint256 decimals;
    }

    mapping(address => PriceData) private prices;

    function setAssetPrice(address asset_, uint256 price_, uint256 decimals_) external {
        prices[asset_] = PriceData({price: price_, decimals: decimals_});
    }

    function getAssetPrice(address asset_) external view returns (uint256 assetPrice, uint256 decimals) {
        PriceData storage p = prices[asset_];
        return (p.price, p.decimals);
    }
}

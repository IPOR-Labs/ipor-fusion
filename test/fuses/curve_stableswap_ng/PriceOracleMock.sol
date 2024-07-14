// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {IPriceOracleMiddleware} from "./../../../contracts/priceOracle/PriceOracleMiddleware.sol";

contract PriceOracleMock is IPriceOracleMiddleware {
    address public immutable baseCurrency;
    uint256 public immutable baseCurrencyDecimals;
    mapping(address => uint256) public prices;

    constructor(address _baseCurrency, uint256 _baseCurrencyDecimals) {
        baseCurrency = _baseCurrency;
        baseCurrencyDecimals = _baseCurrencyDecimals;
    }

    function setPrice(address asset, uint256 price) external {
        prices[asset] = price;
    }

    function getAssetPrice(address asset) external view override returns (uint256) {
        uint256 price = prices[asset];
        require(price > 0, "Price not set for asset");
        return price;
    }

    function getAssetsPrices(address[] calldata assets) external view override returns (uint256[] memory) {
        uint256[] memory assetPrices = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            uint256 price = prices[assets[i]];
            require(price > 0, "Price not set for asset");
            assetPrices[i] = price;
        }
        return assetPrices;
    }

    function getSourceOfAssetPrice(address asset) external view override returns (address) {
        return address(0); // Return address(0) for simplicity in the mock
    }

    function setAssetsPricesSources(address[] calldata assets, address[] calldata sources) external pure override {
        // Do nothing in the mock
    }

    function BASE_CURRENCY() external view override returns (address) {
        return baseCurrency;
    }

    function BASE_CURRENCY_DECIMALS() external view override returns (uint256) {
        return baseCurrencyDecimals;
    }
}

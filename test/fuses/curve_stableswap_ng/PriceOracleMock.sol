// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {IPriceOracleMiddleware} from "./../../../contracts/priceOracle/PriceOracleMiddleware.sol";

contract PriceOracleMock is IPriceOracleMiddleware {
    address public immutable baseCurrency;
    uint256 public immutable baseCurrencyDecimals;

    constructor(address _baseCurrency, uint256 _baseCurrencyDecimals) {
        baseCurrency = _baseCurrency;
        baseCurrencyDecimals = _baseCurrencyDecimals;
    }

    function getAssetPrice(address asset) external pure override returns (uint256) {
        return 1e8; // Return 1 USD in 8 decimal places
    }

    function getAssetsPrices(address[] calldata assets) external pure override returns (uint256[] memory) {
        uint256[] memory prices = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            prices[i] = 1e8; // Return 1 USD for each asset in 8 decimal places
        }
        return prices;
    }

    function getSourceOfAsset(address asset) external view override returns (address) {
        return address(0); // Return address(0) for simplicity in the mock
    }

    function setAssetSources(address[] calldata assets, address[] calldata sources) external pure override {
        // Do nothing in the mock
    }

    function BASE_CURRENCY() external view override returns (address) {
        return baseCurrency;
    }

    function BASE_CURRENCY_DECIMALS() external view override returns (uint256) {
        return baseCurrencyDecimals;
    }
}

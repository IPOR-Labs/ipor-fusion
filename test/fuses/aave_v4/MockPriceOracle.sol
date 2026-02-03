// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IPriceOracleMiddleware} from "../../../contracts/price_oracle/IPriceOracleMiddleware.sol";

/// @title MockPriceOracle
/// @notice Mock implementation of IPriceOracleMiddleware for testing
contract MockPriceOracle is IPriceOracleMiddleware {
    /// @dev Default price decimals (8 decimals like Chainlink)
    uint256 public constant DEFAULT_PRICE_DECIMALS = 8;

    mapping(address => uint256) public prices;
    mapping(address => uint256) public priceDecimals;
    mapping(address => address) public sources;

    /// @notice Sets the price for an asset with default decimals (8)
    /// @param asset_ The asset address
    /// @param price_ The price value
    function setAssetPrice(address asset_, uint256 price_) external {
        prices[asset_] = price_;
        if (priceDecimals[asset_] == 0) {
            priceDecimals[asset_] = DEFAULT_PRICE_DECIMALS;
        }
    }

    /// @notice Sets the price and decimals for an asset
    /// @param asset_ The asset address
    /// @param price_ The price value
    /// @param decimals_ The number of decimals
    function setAssetPriceWithDecimals(address asset_, uint256 price_, uint256 decimals_) external {
        prices[asset_] = price_;
        priceDecimals[asset_] = decimals_;
    }

    /// @inheritdoc IPriceOracleMiddleware
    function getAssetPrice(address asset) external view returns (uint256 assetPrice, uint256 decimals) {
        assetPrice = prices[asset];
        decimals = priceDecimals[asset];
        if (decimals == 0) {
            decimals = DEFAULT_PRICE_DECIMALS;
        }
    }

    /// @inheritdoc IPriceOracleMiddleware
    function getAssetsPrices(
        address[] calldata assets
    ) external view returns (uint256[] memory assetPrices, uint256[] memory decimalsList) {
        uint256 len = assets.length;
        assetPrices = new uint256[](len);
        decimalsList = new uint256[](len);

        for (uint256 i; i < len; ++i) {
            assetPrices[i] = prices[assets[i]];
            decimalsList[i] = priceDecimals[assets[i]];
            if (decimalsList[i] == 0) {
                decimalsList[i] = DEFAULT_PRICE_DECIMALS;
            }
        }
    }

    /// @inheritdoc IPriceOracleMiddleware
    function getSourceOfAssetPrice(address asset) external view returns (address) {
        return sources[asset];
    }

    /// @inheritdoc IPriceOracleMiddleware
    function setAssetsPricesSources(address[] calldata assets, address[] calldata sources_) external {
        for (uint256 i; i < assets.length; ++i) {
            sources[assets[i]] = sources_[i];
        }
    }

    /// @inheritdoc IPriceOracleMiddleware
    //solhint-disable-next-line func-name-mixedcase
    function QUOTE_CURRENCY() external pure returns (address) {
        return address(0);
    }

    /// @inheritdoc IPriceOracleMiddleware
    //solhint-disable-next-line func-name-mixedcase
    function QUOTE_CURRENCY_DECIMALS() external pure returns (uint256) {
        return 18;
    }
}

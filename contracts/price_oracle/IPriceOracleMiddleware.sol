// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title Interface to an aggregator of price feeds for assets, responsible for providing the prices of assets in a given quote currency
interface IPriceOracleMiddleware {
    error EmptyArrayNotSupported();
    error ArrayLengthMismatch();
    error UnexpectedPriceResult();
    error UnsupportedAsset();
    error ZeroAddress(string variableName);
    error WrongDecimals();
    error WrongDecimalsInPriceFeed();

    /// @notice Returns the price of the given asset in given decimals
    /// @return assetPrice price in QUOTE_CURRENCY of the asset
    /// @return decimals number of decimals of the asset price
    function getAssetPrice(address asset) external view returns (uint256 assetPrice, uint256 decimals);

    /// @notice Returns the prices of the given assets in given decimals
    /// @return assetPrices prices in QUOTE_CURRENCY of the assets represented in given decimals
    /// @return decimalsList number of decimals of the asset prices
    function getAssetsPrices(
        address[] calldata assets
    ) external view returns (uint256[] memory assetPrices, uint256[] memory decimalsList);

    /// @notice Returns address of source of the asset price - it could be IPOR Price Feed or Chainlink Aggregator or any other source of price for a given asset
    /// @param asset address of the asset
    /// @return address of the source of the asset price
    function getSourceOfAssetPrice(address asset) external view returns (address);

    /// @notice Sets the sources of the asset prices
    /// @param assets array of addresses of the assets
    function setAssetsPricesSources(address[] calldata assets, address[] calldata sources) external;

    /// @notice Returns the address of the quote currency to which all the prices are relative, in IPOR Fusion it is the USD
    //solhint-disable-next-line
    function QUOTE_CURRENCY() external view returns (address);

    /// @notice Returns the number of decimals of the quote currency, by default it is 8 for USD, but can be different for other types of Price Oracles Middlewares
    //solhint-disable-next-line
    function QUOTE_CURRENCY_DECIMALS() external view returns (uint256);
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title Interface to an aggregator of price feeds for assets
interface IPriceOracleMiddleware {
    error EmptyArrayNotSupported();
    error ArrayLengthMismatch();
    error UnexpectedPriceResult();
    error UnsupportedAsset();
    error ZeroAddress(string variableName);
    error WrongDecimals();

    /// @notice Returns the price of the given asset in 8 decimals
    /// @return price of the asset in 8 decimals
    function getAssetPrice(address asset) external view returns (uint256);

    /// @notice Returns the prices of the given assets in 8 decimals
    /// @return prices of the assets in 8 decimals
    function getAssetsPrices(address[] calldata assets) external view returns (uint256[] memory);

    /// @notice Returns address of source of the asset price - it could be IPOR Price Feed or Chainlink Aggregator or any other source of price for a given asset
    /// @param asset address of the asset
    /// @return address of the source of the asset price
    function getSourceOfAssetPrice(address asset) external view returns (address);

    /// @notice Sets the sources of the asset prices
    /// @param assets array of addresses of the assets
    function setAssetsPricesSources(address[] calldata assets, address[] calldata sources) external;

    /// @notice Returns the address of the base currency to which all the prices are relative, in IPOR Fusion is the USD
    //solhint-disable-next-line
    function BASE_CURRENCY() external view returns (address);

    /// @notice Returns the number of decimals of the base currency
    //solhint-disable-next-line
    function BASE_CURRENCY_DECIMALS() external view returns (uint256);
}

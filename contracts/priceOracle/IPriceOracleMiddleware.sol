// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

interface IPriceOracleMiddleware {
    /// @notice Returns the price of the given asset in 8 decimals
    /// @return price of the asset in 8 decimals
    function getAssetPrice(address asset) external view returns (uint256);

    /// @notice Returns the prices of the given assets in 8 decimals
    /// @return prices of the assets in 8 decimals
    function getAssetsPrices(address[] calldata assets) external view returns (uint256[] memory);

    function getSourceOfAsset(address asset) external view returns (address);

    function setAssetSources(address[] calldata assets, address[] calldata sources) external;

    //solhint-disable-next-line
    function BASE_CURRENCY() external view returns (address);

    //solhint-disable-next-line
    function BASE_CURRENCY_DECIMALS() external view returns (uint256);

    error EmptyArrayNotSupported(string errorCode);
    error ArrayLengthMismatch(string errorCode);
    error UnexpectedPriceResult(string errorCode);
    error UnsupportedAsset(string errorCode);
    error ZeroAddress(string errorCode, string variableName);
}

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

interface IIporPriceOracle {
    /**
     * @notice Returns the base currency address
     * @dev Address 0x0000000000000000000000000000000000000348 is reserved for USD as base currency.
     * @return Returns the base currency address.
     */
    function BASE_CURRENCY() external view returns (address);

    function BASE_CURRENCY_DECIMALS() external view returns (uint256);

    function setAssetSources(address[] calldata assets, address[] calldata sources) external;

    function getAssetPrice(address asset) external view returns (uint256);

    function getAssetsPrices(address[] calldata assets) external view returns (uint256[] memory);

    function getSourceOfAsset(address asset) external view returns (address);

    error EmptyArrayNotSupported(string errorCode);
    error ArrayLengthMismatch(string errorCode);
    error UnsupportedAsset(string errorCode);
    error ZeroAddress(string errorCode, string variableName);
}

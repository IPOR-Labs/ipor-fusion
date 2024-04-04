// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

interface IIporPriceOracle {
    function setAssetSources(address[] calldata assets, address[] calldata sources) external;

    function getAssetPrice(address asset) external view returns (uint256);

    function getAssetsPrices(address[] calldata assets) external view returns (uint256[] memory);

    function getSourceOfAsset(address asset) external view returns (address);

    error EmptyArrayNotSupported(string errorCode);
    error ArrayLengthMismatch(string errorCode);
    error UnsupportedAsset(string errorCode);
    error ZeroAddress(string errorCode, string variableName);
}

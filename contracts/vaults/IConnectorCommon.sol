// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

interface IConnectorCommon {
    function getSupportedAssets()
    external
    view
    returns (address[] memory assets);

    function isSupportedAsset(address asset) external view returns (bool);

    function marketId() external view returns (uint256);
    function marketName() external view returns (string memory);

}

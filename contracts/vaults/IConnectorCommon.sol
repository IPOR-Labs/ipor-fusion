// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

interface IConnectorCommon {
    function getSupportedAssets() external view returns (address[] memory assets);

    function isSupportedAsset(address asset) external view returns (bool);

    //solhint-disable-next-line
    function MARKET_ID() external view returns (uint256);
}

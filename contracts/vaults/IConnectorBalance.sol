// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import "./IConnectorCommon.sol";

interface IConnectorBalance is IConnectorCommon {
    function balanceOf(address account, address underlyingAsset, address asset) external view returns (int256);
}

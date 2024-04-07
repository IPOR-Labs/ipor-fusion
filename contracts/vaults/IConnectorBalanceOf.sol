// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

interface IConnectorBalanceOf {
    function balanceOfMarket(
        address user,
        address[] calldata assets
    ) external view returns (uint256 balanceValue, address balanceAsset);
}

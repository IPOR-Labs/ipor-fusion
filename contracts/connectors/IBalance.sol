// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

interface IBalance {
    function balanceOfMarket(
        address user,
        address[] calldata assets
    ) external view returns (uint256 balances, address balanceAsset);
}

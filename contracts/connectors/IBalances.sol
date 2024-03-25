// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

interface IBalances {
    function balanceOfMarket(
        address[] calldata assets,
        address user
    ) external view returns (uint256 balances, address valuesInAsset);
}

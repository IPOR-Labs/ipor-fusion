// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

interface IBalance {
    /// @notice Get the balance of the user in the market
    /// @dev Notice! Every Balance Fuse have to implement this funciton signature, because is used by Vault engine
    function balanceOfMarket(address user) external view returns (uint256 balanceValue, address balanceAsset);
}

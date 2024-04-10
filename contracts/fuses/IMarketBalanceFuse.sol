// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

interface IMarketBalanceFuse {
    /// @notice Get the balance of the user in the market in USD
    /// @dev Notice! Every Balance Fuse have to implement this function signature, because is used by Vault engine
    /// @param plazmaVault The address of the Plazma Vault
    /// @return balanceValue The balance of the user in the market in USD, represented in 18 decimals
    function balanceOf(address plazmaVault) external view returns (uint256 balanceValue);
}

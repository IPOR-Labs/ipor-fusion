// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title Interface for Fuses responsible for providing the balance of the given address (like PlasmaVault address) in the market in USD
interface IMarketBalanceFuse {
    /// @notice Get the balance of the given address in the market in USD
    /// @dev Notice! Every Balance Fuse have to implement this exact function signature, because it is used by Plasma Vault engine
    /// @param plasmaVault The address of the Plasma Vault
    /// @return balanceValue The balance of the user in the market in USD, represented in 18 decimals
    function balanceOf(address plasmaVault) external returns (uint256 balanceValue);
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title Interface for Fuses responsible for providing the balance of the PlasmaVault address in the market in USD
interface IMarketBalanceFuse {
    /// @notice Get the balance of the Plasma Vault in the market in USD
    /// @dev Notice! Every Balance Fuse have to implement this exact function signature, because it is used by Plasma Vault engine
    /// @return balanceValue The balance of the Plasma Vault in the market in USD, represented in 18 decimals
    function balanceOf() external returns (uint256 balanceValue);
}

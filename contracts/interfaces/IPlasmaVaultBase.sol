// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title Plasma Vault Base interface
interface IPlasmaVaultBase {
    /// @notice Initializes the Plasma Vault
    /// @dev Method is executed only once during the Plasma Vault construction in context of Plasma Vault (delegatecall used)
    /// @param assetName_ The name of the asset
    /// @param accessManager_ The address of the Ipor Fusion Access Manager
    /// @param totalSupplyCap_ The total supply cap of the shares
    function init(string memory assetName_, address accessManager_, uint256 totalSupplyCap_) external;

    /// @notice When token are transferring, updates data in storage required for functionalities included in PlasmaVaultBase but in context of Plasma Vault (delegatecall used)
    /// @param from_ The address from which the tokens are transferred
    /// @param to_ The address to which the tokens are transferred
    /// @param value_ The amount of tokens transferred
    function updateInternal(address from_, address to_, uint256 value_) external;

    /// @notice Transfers request fee tokens from user to withdraw manager
    /// @dev This function is called during the withdraw request process to handle request fee transfers
    ///
    /// Access Control:
    /// - Restricted to TECH_WITHDRAW_MANAGER_ROLE only
    /// - Cannot be called by any other role, including admin or owner
    /// - System-level role assigned during initialization
    /// - Technical role that cannot be reassigned during runtime
    ///
    /// Fee System:
    /// - Transfers request fee tokens from user to withdraw manager
    /// - Part of the withdraw request flow
    /// - Only callable by authorized contracts (restricted)
    /// - Critical for fee collection mechanism
    ///
    /// Integration Context:
    /// - Called by WithdrawManager during requestShares
    /// - Handles fee collection for withdrawal requests
    /// - Maintains fee token balances
    /// - Supports protocol revenue model
    ///
    /// Security Features:
    /// - Access controlled (restricted to TECH_WITHDRAW_MANAGER_ROLE)
    /// - Atomic operation
    /// - State consistency checks
    /// - Integrated with vault permissions
    ///
    /// Use Cases:
    /// - Withdrawal request fee collection
    /// - Protocol revenue generation
    /// - Fee token management
    /// - Automated fee handling
    ///
    /// Related Components:
    /// - WithdrawManager contract (must have TECH_WITHDRAW_MANAGER_ROLE)
    /// - Fee management system
    /// - Access control system
    /// - Token operations
    ///
    /// @param from_ The address from which to transfer the fee tokens
    /// @param to_ The address to which the fee tokens should be transferred (usually withdraw manager)
    /// @param amount_ The amount of fee tokens to transfer
    /// @custom:access TECH_WITHDRAW_MANAGER_ROLE
    function transferRequestSharesFee(address from_, address to_, uint256 amount_) external;
}

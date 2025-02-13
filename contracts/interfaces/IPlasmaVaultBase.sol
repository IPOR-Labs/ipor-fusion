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

    function transferRequestFee(address from_, address to_, uint256 amount_) external;
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PlasmaVaultInitData} from "../vaults/PlasmaVault.sol";
import {PlasmaVault} from "../vaults/PlasmaVault.sol";

/// @title PlasmaVaultFactory
/// @notice Factory contract for creating and deploying new PlasmaVault instances
/// @dev This factory uses the standard deployment pattern rather than minimal proxy pattern
/// @dev Each call to getInstance creates a new, independent PlasmaVault contract
/// @dev The factory emits events for tracking vault creation and initialization parameters
contract PlasmaVaultFactory {
    /// @notice Emitted when a new PlasmaVault is created
    /// @param index The index of the PlasmaVault instance
    /// @param plasmaVault The address of the newly created PlasmaVault
    /// @param assetName The name of the underlying asset
    /// @param assetSymbol The symbol of the underlying asset
    /// @param underlyingToken The address of the underlying token contract
    event PlasmaVaultCreated(uint256 index, address plasmaVault, string assetName, string assetSymbol, address underlyingToken);

    /// @notice Creates a new PlasmaVault instance with the specified initialization parameters
    /// @param index_ The index of the PlasmaVault instance
    /// @param initData_ The initialization data containing vault configuration parameters
    /// @return plasmaVault The address of the newly created PlasmaVault contract
    /// @dev This function deploys a new PlasmaVault contract with the provided initialization data
    /// @dev The initialization data must contain valid parameters for the vault to function correctly
    function create(uint256 index_, PlasmaVaultInitData memory initData_) external returns (address plasmaVault) {
        plasmaVault = address(new PlasmaVault(initData_));
        emit PlasmaVaultCreated(index_, plasmaVault, initData_.assetName, initData_.assetSymbol, initData_.underlyingToken);
    }
}

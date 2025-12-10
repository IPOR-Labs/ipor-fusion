// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PlasmaVaultStorageLib} from "../../contracts/libraries/PlasmaVaultStorageLib.sol";

/// @notice This contract is for testing purposes only
/// @dev Do not use in production environment

contract UpdateWithdrawManager {
    /// @notice Updates the withdraw manager address in storage
    /// @param newManager The address of the new withdraw manager
    function updateWithdrawManager(address newManager) external {
        // Get storage pointer for WithdrawManager
        PlasmaVaultStorageLib.WithdrawManager storage withdrawManager = PlasmaVaultStorageLib.getWithdrawManager();

        // Update the manager address
        withdrawManager.manager = newManager;
    }

    /// @notice Gets the current withdraw manager address
    /// @return The address of the current withdraw manager
    function getWithdrawManager() external view returns (address) {
        // Get storage pointer and return current manager
        return PlasmaVaultStorageLib.getWithdrawManager().manager;
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PlasmaVaultStorageLib} from "../libraries/PlasmaVaultStorageLib.sol";

/// @title PreHooksLib
/// @notice Library for handling pre-execution hooks in Plasma Vault operations
/// @dev Provides validation and setup logic to run before main vault operations
library PreHooksLib {
    /// @notice Error thrown when input arrays have different lengths
    error PreHooksLib_InvalidArrayLength();
    /// @notice Error thrown when selector is zero
    error PreHooksLib_InvalidSelector();

    /// @notice Emitted when a pre-hook implementation is changed for a function selector
    /// @param selector The function selector that was updated
    /// @param newImplementation The new implementation address (address(0) if it was removed)
    event PreHookImplementationChanged(bytes4 indexed selector, address newImplementation);

    /// @notice Returns the pre-hook implementation address for a given function signature
    /// @dev Uses PlasmaVaultStorageLib to access the pre-hooks configuration
    /// @param selector_ The function selector to get the pre-hook implementation for
    /// @return The address of the pre-hook implementation contract, or address(0) if not found
    function getPreHookImplementation(bytes4 selector_) internal view returns (address) {
        PlasmaVaultStorageLib.PreHooksConfig storage preHooksConfig = PlasmaVaultStorageLib.getPreHooksConfig();
        return preHooksConfig.hooksImplementation[selector_];
    }

    /// @notice Returns all function selectors that have pre-hooks configured
    /// @dev Retrieves the complete list of selectors from storage
    /// @return Array of function selectors (bytes4) with configured pre-hooks
    function getPreHookSelectors() internal view returns (bytes4[] memory) {
        PlasmaVaultStorageLib.PreHooksConfig storage preHooksConfig = PlasmaVaultStorageLib.getPreHooksConfig();
        return preHooksConfig.selectors;
    }

    /// @notice Sets new implementation addresses for given function selectors
    /// @dev Updates or adds new pre-hook implementations and maintains the selectors array
    /// @param selectors_ Array of function selectors to set implementations for
    /// @param implementations_ Array of implementation addresses corresponding to selectors
    function setPreHookImplementations(bytes4[] calldata selectors_, address[] calldata implementations_) internal {
        if (selectors_.length != implementations_.length) {
            revert PreHooksLib_InvalidArrayLength();
        }

        PlasmaVaultStorageLib.PreHooksConfig storage preHooksConfig = PlasmaVaultStorageLib.getPreHooksConfig();

        bytes4 selector;
        address implementation;
        address oldImplementation;
        uint256 selectorsLength = selectors_.length;
        for (uint256 i; i < selectorsLength; ++i) {
            selector = selectors_[i];
            implementation = implementations_[i];

            if (selector == bytes4(0)) {
                revert PreHooksLib_InvalidSelector();
            }

            oldImplementation = preHooksConfig.hooksImplementation[selector];

            // If this is a new selector, add it to the array and update its index
            if (oldImplementation == address(0) && implementation != address(0)) {
                preHooksConfig.selectors.push(selector);
                preHooksConfig.indexes[selector] = preHooksConfig.selectors.length - 1;
            }
            // If we're removing an implementation, swap and pop from the selectors array
            else if (oldImplementation != address(0) && implementation == address(0)) {
                uint256 index = preHooksConfig.indexes[selector];
                uint256 lastIndex = preHooksConfig.selectors.length - 1;

                if (index != lastIndex) {
                    bytes4 lastSelector = preHooksConfig.selectors[lastIndex];
                    preHooksConfig.selectors[index] = lastSelector;
                    preHooksConfig.indexes[lastSelector] = index;
                }
                preHooksConfig.selectors.pop();
                delete preHooksConfig.indexes[selector];
            }

            preHooksConfig.hooksImplementation[selector] = implementation;

            emit PreHookImplementationChanged(selector, implementation);
        }
    }
}

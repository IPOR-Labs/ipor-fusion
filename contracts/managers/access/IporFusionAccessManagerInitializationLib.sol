// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IporFusionAccessManagersStorageLib, InitializationFlag} from "./IporFusionAccessManagersStorageLib.sol";

/**
 * @title Role-to-Function Mapping Structure
 * @notice Defines the relationship between roles and their authorized function calls
 * @dev Used to configure function-level access control during initialization
 */
struct RoleToFunction {
    /// @notice The target contract address where the function resides
    address target;
    /// @notice The role identifier that has permission to call the function
    uint64 roleId;
    /// @notice The 4-byte function selector of the authorized function
    bytes4 functionSelector;
    /// @notice Timelock delay for function execution
    /// @dev If greater than 0, function calls require waiting for the specified delay
    uint256 minimalExecutionDelay;
}

/**
 * @title Admin Role Configuration Structure
 * @notice Defines the hierarchical relationship between roles
 * @dev Used to establish role administration rights
 */
struct AdminRole {
    /// @notice The role being administered
    uint64 roleId;
    /// @notice The role that has admin rights over roleId
    uint64 adminRoleId;
}

/**
 * @title Account-to-Role Assignment Structure
 * @notice Maps accounts to their assigned roles with optional execution delays
 * @dev Used to configure initial role assignments during initialization
 */
struct AccountToRole {
    /// @notice The role being assigned
    uint64 roleId;
    /// @notice The account receiving the role
    address account;
    /// @notice Account-specific execution delay
    /// @dev If greater than 0, the account must wait this period before executing role actions
    uint32 executionDelay;
}

/**
 * @title Access Manager Initialization Configuration
 * @notice Comprehensive structure for initializing the access control system
 * @dev Combines all necessary configuration data for one-time initialization
 */
struct InitializationData {
    /// @notice Array of function access configurations
    RoleToFunction[] roleToFunctions;
    /// @notice Array of initial role assignments
    AccountToRole[] accountToRoles;
    /// @notice Array of role hierarchy configurations
    AdminRole[] adminRoles;
}

/**
 * @title IPOR Fusion Access Manager Initialization Library
 * @notice Manages one-time initialization of access control settings
 * @dev Implements initialization protection to prevent multiple configurations
 * @custom:security-contact security@ipor.io
 */
library IporFusionAccessManagerInitializationLib {
    /// @notice Emitted when the access manager is successfully initialized
    event IporFusionAccessManagerInitialized();

    /// @notice Thrown when attempting to initialize an already initialized contract
    error AlreadyInitialized();

    /**
     * @notice Verifies and sets the initialization state
     * @dev Ensures the contract can only be initialized once
     * @custom:security Critical function that prevents multiple initializations
     * @custom:error-handling Reverts with AlreadyInitialized if already initialized
     */
    function isInitialized() internal {
        InitializationFlag storage initializationFlag = IporFusionAccessManagersStorageLib.getInitializationFlag();
        if (initializationFlag.initialized > 0) {
            revert AlreadyInitialized();
        }
        initializationFlag.initialized = 1;
        emit IporFusionAccessManagerInitialized();
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IporFusionAccessManagersStorageLib, InitializationFlag} from "./IporFusionAccessManagersStorageLib.sol";

/// @notice Struct for the role-to-function mapping
struct RoleToFunction {
    /// @notice The target contract address
    address target;
    /// @notice The role ID
    uint64 roleId;
    /// @notice The function selector
    bytes4 functionSelector;
    /// @notice The minimal execution delay, if greater than 0 then the function is timelocked
    uint256 minimalExecutionDelay;
}

/// @notice Struct for the admin role mapping
struct AdminRole {
    /// @notice The role ID
    uint64 roleId;
    /// @notice The admin role ID
    uint64 adminRoleId;
}

/// @notice Struct for the account-to-role mapping
struct AccountToRole {
    /// @notice The role ID
    uint64 roleId;
    /// @notice The account address
    address account;
    /// @notice The account lock time, if greater than 0 then the execution is timelocked for a given account
    uint32 executionDelay;
}

/// @notice Struct for the initialization data for the IporFusionAccessManager contract
struct InitializationData {
    /// @notice The role-to-function mappings
    RoleToFunction[] roleToFunctions;
    /// @notice The account-to-role mappings
    AccountToRole[] accountToRoles;
    /// @notice The admin role mappings
    AdminRole[] adminRoles;
}

/// @title Library for initializing the IporFusionAccessManager contract, initializing the contract can only be done once
library IporFusionAccessManagerInitializationLib {
    event IporFusionAccessManagerInitialized();
    error AlreadyInitialized();

    /// @notice Checks if the contract is already initialized
    /// @dev The function checks if the contract is already initialized, if it is, it reverts with an error
    function isInitialized() internal {
        InitializationFlag storage initializationFlag = IporFusionAccessManagersStorageLib.getInitializationFlag();
        if (initializationFlag.initialized > 0) {
            revert AlreadyInitialized();
        }
        initializationFlag.initialized = 1;
        emit IporFusionAccessManagerInitialized();
    }
}

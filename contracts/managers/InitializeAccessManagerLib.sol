// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {ManagersStorageLib, InitializeAccessManager} from "./ManagersStorageLib.sol";

struct RoleToFunction {
    address target;
    uint64 roleId;
    bytes4 functionSelector;
    uint256 minimalExecutionDelay;
}

struct AdminRoles {
    uint64 roleId;
    uint64 adminRoleId;
}

struct AccountToRole {
    uint64 roleId;
    address account;
    uint32 executionDelay;
}

struct InitializeData {
    RoleToFunction[] roleToFunctions;
    AccountToRole[] accountToRoles;
    AdminRoles[] adminRoles;
    uint256 redemptionDelay;
}

library InitializeAccessManagerLib {
    /**
     * @dev Triggered when the contract has been initialized
     */
    event Initialized();

    error AlreadyInitialized();

    function isInitialized() internal {
        InitializeAccessManager storage initialize = ManagersStorageLib.getInitializeAccessManager();
        if (initialize.initialized > 0) {
            revert AlreadyInitialized();
        }
        initialize.initialized = 1;
        emit Initialized();
    }
}

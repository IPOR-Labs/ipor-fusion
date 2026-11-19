// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IporFusionAccessManagersStorageLib} from "./IporFusionAccessManagersStorageLib.sol";

/**
 * @title Role Execution Timelock Library
 * @notice Manages time-based restrictions on role execution permissions
 * @dev Implements timelock functionality for role-based actions to enhance security
 * through mandatory waiting periods
 * @custom:security-contact security@ipor.io
 */
library RoleExecutionTimelockLib {
    /**
     * @notice Emitted when a role's minimal execution delay is modified
     * @param roleId The identifier of the role whose delay was updated
     * @param delay The new minimal execution delay in seconds
     */
    event MinimalExecutionDelayForRoleUpdated(uint64 roleId, uint256 delay);

    /**
     * @notice Thrown when a minimal execution delay does not fit the `uint32` execution delay of an access manager role
     * @param roleId The identifier of the role the delay was set for
     * @param delay The rejected delay in seconds
     */
    error RoleExecutionTimelockLibDelayFloorTooLarge(uint64 roleId, uint256 delay);

    /**
     * @notice Retrieves the minimum waiting period required before executing actions for a role
     * @dev A delay greater than 0 indicates that actions for this role are timelocked
     * @param roleId_ The identifier of the role to query
     * @return The minimum delay period in seconds
     * @custom:security This delay acts as a security measure for sensitive operations
     */
    function getMinimalExecutionDelayForRole(uint64 roleId_) internal view returns (uint256) {
        return IporFusionAccessManagersStorageLib.getMinimalExecutionDelayForRole().delays[roleId_];
    }

    /**
     * @notice Configures timelock delays for multiple roles
     * @dev Batch operation to set execution delays for multiple roles at once
     * @param roleIds_ Array of role identifiers to configure
     * @param delays_ Array of corresponding delay periods in seconds
     * @custom:security Critical function that affects access control timing
     * @custom:error-handling Only `roleIds_.length` is iterated and the lengths are not compared: a shorter `delays_`
     *         reverts with an out-of-bounds panic, a longer one has its extra values ignored. Callers must pass arrays of
     *         equal length (IL-9682)
     * @custom:error RoleExecutionTimelockLibDelayFloorTooLarge if a delay exceeds `type(uint32).max`: the execution
     *         delay granted with a role is a `uint32`, so a larger floor could never be satisfied and no account could
     *         receive the role (IL-9676)
     */
    function setMinimalExecutionDelaysForRoles(uint64[] memory roleIds_, uint256[] memory delays_) internal {
        uint256 length = roleIds_.length;
        for (uint256 i; i < length; ++i) {
            if (delays_[i] > type(uint32).max) {
                revert RoleExecutionTimelockLibDelayFloorTooLarge(roleIds_[i], delays_[i]);
            }
            IporFusionAccessManagersStorageLib.getMinimalExecutionDelayForRole().delays[roleIds_[i]] = delays_[i];
            emit MinimalExecutionDelayForRoleUpdated(roleIds_[i], delays_[i]);
        }
    }
}

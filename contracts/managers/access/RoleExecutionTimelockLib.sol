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
     * @custom:error-handling Arrays must be of equal length
     */
    function setMinimalExecutionDelaysForRoles(uint64[] memory roleIds_, uint256[] memory delays_) internal {
        uint256 length = roleIds_.length;
        for (uint256 i; i < length; ++i) {
            IporFusionAccessManagersStorageLib.getMinimalExecutionDelayForRole().delays[roleIds_[i]] = delays_[i];
            emit MinimalExecutionDelayForRoleUpdated(roleIds_[i], delays_[i]);
        }
    }
}

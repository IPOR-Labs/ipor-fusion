// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {IporFusionAccessManagersStorageLib} from "./IporFusionAccessManagersStorageLib.sol";

library RoleExecutionTimelockLib {
    event MinimalExecutionDelayForRoleUpdated(uint64 roleId, uint256 delay);

    /// @notice Gets the minimal execution delay for a role. When value is higher than 0, it means that actions for a given role have a timelock.
    function getMinimalExecutionDelayForRole(uint64 roleId_) internal view returns (uint256) {
        return IporFusionAccessManagersStorageLib.getMinimalExecutionDelayForRole().delays[roleId_];
    }

    /// @notice Sets the minimal execution delays for roles. The delays are used to timelock actions for a given role.
    function setMinimalExecutionDelaysForRoles(uint64[] memory roleIds_, uint256[] memory delays_) internal {
        uint256 length = roleIds_.length;
        for (uint256 i; i < length; ++i) {
            IporFusionAccessManagersStorageLib.getMinimalExecutionDelayForRole().delays[roleIds_[i]] = delays_[i];
            emit MinimalExecutionDelayForRoleUpdated(roleIds_[i], delays_[i]);
        }
    }
}

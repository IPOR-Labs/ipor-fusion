// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {ManagersStorageLib} from "./ManagersStorageLib.sol";

library RoleExecutionTimelockLib {
    event MinimalExecutionDelayForRoleUpdated(uint64 roleId, uint256 delay);

    function getMinimalExecutionDelayForRole(uint64 roleId_) internal view returns (uint256) {
        return ManagersStorageLib._getMinimalExecutionDelayForRole().delays[roleId_];
    }

    function setMinimalExecutionDelaysForRoles(uint64[] calldata roleIds_, uint256[] calldata delays_) internal {
        uint256 length = roleIds_.length;
        for (uint256 i; i < length; i++) {
            ManagersStorageLib._getMinimalExecutionDelayForRole().delays[roleIds_[i]] = delays_[i];
            emit MinimalExecutionDelayForRoleUpdated(roleIds_[i], delays_[i]);
        }
    }
}

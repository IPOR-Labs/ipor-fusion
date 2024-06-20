// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {ManagersStorageLib} from "./ManagersStorageLib.sol";

library RoleExecutionTimelockLib {
    event RoleExecutionTimelockUpdated(uint64 role, uint256 delay);

    function getRoleExecutionTimelock(uint64 role_) internal view returns (uint256) {
        return ManagersStorageLib._getMinimalRoleExecutionTimelock().executionsTimelocks[role_];
    }

    function setRoleExecutionsTimelocks(uint64[] calldata roles_, uint256[] calldata delays_) internal {
        uint256 length = roles_.length;
        for (uint256 i; i < length; i++) {
            ManagersStorageLib._getMinimalRoleExecutionTimelock().executionsTimelocks[roles_[i]] = delays_[i];
            emit RoleExecutionTimelockUpdated(roles_[i], delays_[i]);
        }
    }
}

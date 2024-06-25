// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import {RedemptionDelayLib} from "./RedemptionDelayLib.sol";
import {PlasmaVault} from "../vaults/PlasmaVault.sol";
import {RoleExecutionTimelockLib} from "./RoleExecutionTimelockLib.sol";
import {InitializeAccessManagerLib, InitializeData} from "./InitializeAccessManagerLib.sol";
import {IporFusionRoles} from "../libraries/IporFusionRoles.sol";

contract IporFusionAccessManager is AccessManager {
    error AccessManagedUnauthorized(address caller);
    error TooShortExecutionDelayForRole(uint64 roleId, uint32 executionDelay);

    bool private _customConsumingSchedule;

    modifier restricted() {
        _checkCanCall(_msgSender(), _msgData());
        _;
    }

    constructor(address initialAdmin_) AccessManager(initialAdmin_) {}

    function initialize(InitializeData calldata initialData_) external restricted {
        InitializeAccessManagerLib.isInitialized();

        uint256 roleToFunctionsLength = initialData_.roleToFunctions.length;
        uint64[] memory roleIds = new uint64[](roleToFunctionsLength);
        uint256[] memory minimalDelays = new uint256[](roleToFunctionsLength);

        if (roleToFunctionsLength > 0) {
            for (uint256 i; i < roleToFunctionsLength; ++i) {
                _setTargetFunctionRole(
                    initialData_.roleToFunctions[i].target,
                    initialData_.roleToFunctions[i].functionSelector,
                    initialData_.roleToFunctions[i].roleId
                );
                roleIds[i] = initialData_.roleToFunctions[i].roleId;
                minimalDelays[i] = initialData_.roleToFunctions[i].minimalExecutionDelay;
                if (
                    initialData_.roleToFunctions[i].roleId != IporFusionRoles.ADMIN_ROLE &&
                    initialData_.roleToFunctions[i].roleId != IporFusionRoles.GUARDIAN_ROLE &&
                    initialData_.roleToFunctions[i].roleId != IporFusionRoles.PUBLIC_ROLE
                ) {
                    _setRoleGuardian(initialData_.roleToFunctions[i].roleId, IporFusionRoles.GUARDIAN_ROLE);
                }
            }
        }
        RoleExecutionTimelockLib.setMinimalExecutionDelaysForRoles(roleIds, minimalDelays);

        uint256 adminRolesLength = initialData_.adminRoles.length;
        if (adminRolesLength > 0) {
            for (uint256 i; i < adminRolesLength; ++i) {
                _setRoleAdmin(initialData_.adminRoles[i].roleId, initialData_.adminRoles[i].adminRoleId);
            }
        }

        uint256 accountToRolesLength = initialData_.accountToRoles.length;
        if (accountToRolesLength > 0) {
            for (uint256 i; i < accountToRolesLength; ++i) {
                _grantRoleInternal(
                    initialData_.accountToRoles[i].roleId,
                    initialData_.accountToRoles[i].account,
                    initialData_.accountToRoles[i].executionDelay
                );
            }
        }
        if (initialData_.redemptionDelay > 0) {
            RedemptionDelayLib.setRedemptionDelay(initialData_.redemptionDelay);
        }
    }

    function canCallAndUpdate(
        address caller,
        address target,
        bytes4 selector
    ) external returns (bool immediate, uint32 delay) {
        RedemptionDelayLib.lockChecks(caller, selector);
        return super.canCall(caller, target, selector);
    }

    function updateTargetClosed(address target, bool closed) public restricted {
        _setTargetClosed(target, closed);
    }

    function convertToPublicVault(address vault) public restricted {
        _setTargetFunctionRole(vault, PlasmaVault.mint.selector, PUBLIC_ROLE);
        _setTargetFunctionRole(vault, PlasmaVault.deposit.selector, PUBLIC_ROLE);
    }

    function enableTransferShares(address vault) public restricted {
        _setTargetFunctionRole(vault, PlasmaVault.transfer.selector, PUBLIC_ROLE);
        _setTargetFunctionRole(vault, PlasmaVault.transferFrom.selector, PUBLIC_ROLE);
    }

    function setRedemptionDelay(uint256 delay_) external restricted {
        RedemptionDelayLib.setRedemptionDelay(delay_);
    }

    function setMinimalExecutionDelaysForRoles(
        uint64[] calldata rolesId_,
        uint256[] calldata delays_
    ) external restricted {
        RoleExecutionTimelockLib.setMinimalExecutionDelaysForRoles(rolesId_, delays_);
    }

    function grantRole(uint64 roleId_, address account_, uint32 executionDelay_) public override onlyAuthorized {
        _grantRoleInternal(roleId_, account_, executionDelay_);
    }

    function _grantRoleInternal(uint64 roleId_, address account_, uint32 executionDelay_) internal {
        if (executionDelay_ < RoleExecutionTimelockLib.getMinimalExecutionDelayForRole(roleId_)) {
            revert TooShortExecutionDelayForRole(roleId_, executionDelay_);
        }
        _grantRole(roleId_, account_, getRoleGrantDelay(roleId_), executionDelay_);
    }

    function getMinimalExecutionDelayForRole(uint64 roleId_) external view returns (uint256) {
        return RoleExecutionTimelockLib.getMinimalExecutionDelayForRole(roleId_);
    }

    function getAccountLockTime(address account_) external view returns (uint256) {
        return RedemptionDelayLib.getAccountLockTime(account_);
    }

    function getRedemptionDelay() external view returns (uint256) {
        return RedemptionDelayLib.getRedemptionDelay();
    }

    function isConsumingScheduledOp() public view returns (bytes4) {
        return _customConsumingSchedule ? this.isConsumingScheduledOp.selector : bytes4(0);
    }

    function _checkCanCall(address caller, bytes calldata data) internal virtual {
        (bool immediate, uint32 delay) = canCall(caller, address(this), bytes4(data[0:4]));
        if (!immediate) {
            if (delay > 0) {
                _customConsumingSchedule = true;
                IAccessManager(address(this)).consumeScheduledOp(caller, data);
                _customConsumingSchedule = false;
            } else {
                revert AccessManagedUnauthorized(caller);
            }
        }
    }
}

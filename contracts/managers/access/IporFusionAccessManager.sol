// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {IIporFusionAccessManager} from "../../interfaces/IIporFusionAccessManager.sol";

import {RedemptionDelayLib} from "./RedemptionDelayLib.sol";
import {PlasmaVault} from "../../vaults/PlasmaVault.sol";
import {RoleExecutionTimelockLib} from "./RoleExecutionTimelockLib.sol";
import {IporFusionAccessManagerInitializationLib, InitializationData} from "./IporFusionAccessManagerInitializationLib.sol";
import {Roles} from "../../libraries/Roles.sol";

contract IporFusionAccessManager is IIporFusionAccessManager, AccessManager {
    error AccessManagedUnauthorized(address caller);
    error TooShortExecutionDelayForRole(uint64 roleId, uint32 executionDelay);

    bool private _customConsumingSchedule;

    modifier restricted() {
        _checkCanCall(_msgSender(), _msgData());
        _;
    }

    constructor(address initialAdmin_) AccessManager(initialAdmin_) {}

    /// @notice Initializes the IporFusionAccessManager with the specified initial data.
    /// @param initialData_ A struct containing the initial configuration data, including role-to-function mappings and execution delays.
    /// @dev This method sets up the initial roles, functions, and minimal execution delays. It uses the IporFusionAccessManagerInitializationLib
    /// to ensure that the contract is not already initialized, it can be done only once. The function is restricted to authorized callers.
    function initialize(InitializationData calldata initialData_) external restricted {
        IporFusionAccessManagerInitializationLib.isInitialized();
        _revokeRole(ADMIN_ROLE, msg.sender);

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
                    initialData_.roleToFunctions[i].roleId != Roles.ADMIN_ROLE &&
                    initialData_.roleToFunctions[i].roleId != Roles.GUARDIAN_ROLE &&
                    initialData_.roleToFunctions[i].roleId != Roles.PUBLIC_ROLE
                ) {
                    _setRoleGuardian(initialData_.roleToFunctions[i].roleId, Roles.GUARDIAN_ROLE);
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
        address caller_,
        address target_,
        bytes4 selector_
    ) external override returns (bool immediate, uint32 delay) {
        RedemptionDelayLib.lockChecks(caller_, selector_);
        return super.canCall(caller_, target_, selector_);
    }

    function updateTargetClosed(address target_, bool closed_) external override restricted {
        _setTargetClosed(target_, closed_);
    }

    function convertToPublicVault(address vault_) external override restricted {
        _setTargetFunctionRole(vault_, PlasmaVault.mint.selector, PUBLIC_ROLE);
        _setTargetFunctionRole(vault_, PlasmaVault.deposit.selector, PUBLIC_ROLE);
        _setTargetFunctionRole(vault_, PlasmaVault.depositWithPermit.selector, PUBLIC_ROLE);
    }

    function enableTransferShares(address vault_) external override restricted {
        _setTargetFunctionRole(vault_, PlasmaVault.transfer.selector, PUBLIC_ROLE);
        _setTargetFunctionRole(vault_, PlasmaVault.transferFrom.selector, PUBLIC_ROLE);
    }

    function setRedemptionDelay(uint256 delay_) external override restricted {
        RedemptionDelayLib.setRedemptionDelay(delay_);
    }

    function setMinimalExecutionDelaysForRoles(
        uint64[] calldata rolesIds_,
        uint256[] calldata delays_
    ) external override restricted {
        RoleExecutionTimelockLib.setMinimalExecutionDelaysForRoles(rolesIds_, delays_);
    }

    function grantRole(
        uint64 roleId_,
        address account_,
        uint32 executionDelay_
    ) public override(IAccessManager, AccessManager) onlyAuthorized {
        _grantRoleInternal(roleId_, account_, executionDelay_);
    }

    function getMinimalExecutionDelayForRole(uint64 roleId_) external view override returns (uint256) {
        return RoleExecutionTimelockLib.getMinimalExecutionDelayForRole(roleId_);
    }

    function getAccountLockTime(address account_) external view override returns (uint256) {
        return RedemptionDelayLib.getAccountLockTime(account_);
    }

    function getRedemptionDelay() external view override returns (uint256) {
        return RedemptionDelayLib.getRedemptionDelay();
    }

    function isConsumingScheduledOp() external view override returns (bytes4) {
        return _customConsumingSchedule ? this.isConsumingScheduledOp.selector : bytes4(0);
    }

    function _grantRoleInternal(uint64 roleId_, address account_, uint32 executionDelay_) internal {
        if (executionDelay_ < RoleExecutionTimelockLib.getMinimalExecutionDelayForRole(roleId_)) {
            revert TooShortExecutionDelayForRole(roleId_, executionDelay_);
        }
        _grantRole(roleId_, account_, getRoleGrantDelay(roleId_), executionDelay_);
    }

    function _checkCanCall(address caller_, bytes calldata data_) internal virtual {
        (bool immediate, uint32 delay) = canCall(caller_, address(this), bytes4(data_[0:4]));
        if (!immediate) {
            if (delay > 0) {
                _customConsumingSchedule = true;
                IAccessManager(address(this)).consumeScheduledOp(caller_, data_);
                _customConsumingSchedule = false;
            } else {
                revert AccessManagedUnauthorized(caller_);
            }
        }
    }
}

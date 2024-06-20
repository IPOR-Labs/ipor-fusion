// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import {RedemptionDelayLib} from "./RedemptionDelayLib.sol";
import {PlasmaVault} from "../vaults/PlasmaVault.sol";
import {RoleExecutionTimelockLib} from "./RoleExecutionTimelockLib.sol";

contract IporFusionAccessManager is AccessManager {
    error AccessManagedUnauthorized(address caller);

    bool private _customConsumingSchedule;

    modifier restricted() {
        _checkCanCall(_msgSender(), _msgData());
        _;
    }

    constructor(address initialAdmin_) AccessManager(initialAdmin_) {}

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

    function setRoleExecutionsTimelocks(uint64[] calldata roles_, uint256[] calldata delays_) external restricted {
        RoleExecutionTimelockLib.setRoleExecutionsTimelocks(roles_, delays_);
    }

    function getRoleExecutionTimelock(uint64 role_) external view returns (uint256) {
        return RoleExecutionTimelockLib.getRoleExecutionTimelock(role_);
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

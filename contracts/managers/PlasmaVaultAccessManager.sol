// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {RedemptionDelayLib} from "./RedemptionDelayLib.sol";

contract PlasmaVaultAccessManager is AccessManager {
    constructor(address initialAdmin_) AccessManager(initialAdmin_) {}

    function canCallAndUpdate(
        address caller,
        address target,
        bytes4 selector
    ) external returns (bool immediate, uint32 delay) {
        RedemptionDelayLib.lockChecks(caller, selector);
        return super.canCall(caller, target, selector);
    }

    function canCall(
        address caller,
        address target,
        bytes4 selector
    ) public view override returns (bool immediate, uint32 delay) {
        return super.canCall(caller, target, selector);
    }

    function setRedemptionDelay(uint256 delay_) external onlyAuthorized {
        RedemptionDelayLib.setRedemptionDelay(delay_);
    }

    function getAccountLockTime(address account_) external view returns (uint256) {
        return RedemptionDelayLib.getAccountLockTime(account_);
    }
}

// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

contract PlasmaVaultAccessManager is AccessManager {
    constructor(address initialAdmin_) AccessManager(initialAdmin_) {}

    function canCall(
        address caller,
        address target,
        bytes4 selector
    ) public view override returns (bool immediate, uint32 delay) {
        return super.canCall(caller, target, selector);
    }
}
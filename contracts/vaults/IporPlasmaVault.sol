// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {PlasmaVault, PlasmaVaultInitData} from "./PlasmaVault.sol";

contract IporPlasmaVault is PlasmaVault {
    constructor(PlasmaVaultInitData memory initData_) PlasmaVault(initData_) {}
}

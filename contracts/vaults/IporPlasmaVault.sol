// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {PlasmaVault, PlasmaVaultInitData} from "./PlasmaVault.sol";

contract IporPlasmaVault is PlasmaVault {
    constructor(PlasmaVaultInitData memory initData_) PlasmaVault(initData_) {}
}

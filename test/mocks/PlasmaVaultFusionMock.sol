// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {PlasmaVaultInitData} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultFusion} from "../../contracts/vaults/extensions/PlasmaVaultFusion.sol";

contract PlasmaVaultFusionMock is PlasmaVaultFusion {
    constructor(PlasmaVaultInitData memory initData_) PlasmaVaultFusion(initData_) {}
}

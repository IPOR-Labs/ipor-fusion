// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {PlasmaVault, PlasmaVaultInitData} from "../PlasmaVault.sol";

/// @title PlasmaVault combined with ERC20Permit and ERC20Votes
abstract contract PlasmaVaultFusion is PlasmaVault {
    constructor(PlasmaVaultInitData memory initData_) PlasmaVault(initData_) {}
}

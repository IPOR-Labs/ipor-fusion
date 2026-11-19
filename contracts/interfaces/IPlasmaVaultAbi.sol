// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IPlasmaVault} from "./IPlasmaVault.sol";
import {IPlasmaVaultGovernance} from "./IPlasmaVaultGovernance.sol";
import {IPlasmaVaultRequestCap} from "./IPlasmaVaultRequestCap.sol";

/// @title Plasma Vault  ABI interface
interface IPlasmaVaultAbi is IERC4626, IPlasmaVaultGovernance, IAccessManaged, IPlasmaVault, IPlasmaVaultRequestCap {
    // solhint-disable-previous-line no-empty-blocks
}

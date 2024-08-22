// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IPlasmaVault} from "./IPlasmaVault.sol";
import {IPlasmaVaultGovernance} from "./IPlasmaVaultGovernance.sol";

/// @title Plasma Vault  ABI interface
interface IPlasmaVaultAbi is IERC4626, IPlasmaVaultGovernance, IAccessManaged, IPlasmaVault {
    // solhint-disable-previous-line no-empty-blocks
}

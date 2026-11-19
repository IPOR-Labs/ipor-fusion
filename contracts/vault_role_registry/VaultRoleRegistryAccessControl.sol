// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

/**
 * @title VaultRoleRegistryAccessControl
 * @dev Abstract contract for managing access control of the VaultRoleRegistry.
 * Inherits from AccessControlEnumerableUpgradeable to provide role-based access control with enumeration capabilities.
 */
abstract contract VaultRoleRegistryAccessControl is AccessControlEnumerableUpgradeable {
    /// @notice Role that allows managing the catalogue of assignable roles
    /// @dev bytes32 - 0x66465a4ec8cb5eb97825121a3897b7b55c30a966ddcaa0a50add1fcb6f993a50
    bytes32 public constant ROLES_CATALOG_MANAGER_ROLE = keccak256("ROLES_CATALOG_MANAGER_ROLE");

    /// @notice Role that allows clearing every assignment of a vault with `removeVault`
    /// @dev bytes32 - 0xba21cdfb216f72003487159d27ff18009620a7ed7c2f5f5a1a9fdd8491f84f1a
    bytes32 public constant VAULT_REMOVER_ROLE = keccak256("VAULT_REMOVER_ROLE");

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the access control module. The default admin role must be granted by the inheriting contract.
     */
    // solhint-disable-next-line func-name-mixedcase
    function __VaultRoleRegistryAccessControl_init() internal onlyInitializing {
        __AccessControlEnumerable_init();
        __VaultRoleRegistryAccessControl_init_unchained();
    }

    // solhint-disable-next-line func-name-mixedcase
    function __VaultRoleRegistryAccessControl_init_unchained() internal onlyInitializing {}
}

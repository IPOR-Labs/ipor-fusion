// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

/// @title Predefined roles used in the PlasmaVault contract and its perypheral contracts (managers, fuses, etc.)
/// @notice For documentation purposes: When new roles are added by authorized property of PlasmaVault during runtime, they should be added and described here as well.
library PlasmaVaultRoles {
    uint64 public constant SUPER_ADMIN_ROLE = 0;

    /// @dev Managed by the SuperAdmin
    uint64 public constant EMERGENCY_ROLE = 1;

    uint64 public constant ATOMIST_ADMIN_ROLE = 2;
    uint64 public constant ATOMIST_ROLE = 10;

    uint64 public constant ALPHA_ADMIN_ROLE = 100;
    uint64 public constant ALPHA_ROLE = 110;

    uint64 public constant FUSE_MANAGER_ADMIN_ROLE = 200;
    uint64 public constant FUSE_MANAGER_ROLE = 210;

    uint64 public constant PERFORMANCE_FEE_MANAGER_ADMIN_ROLE = 300;
    uint64 public constant PERFORMANCE_FEE_MANAGER_ROLE = 310;

    uint64 public constant MANAGEMENT_FEE_MANAGER_ADMIN_ROLE = 400;
    uint64 public constant MANAGEMENT_FEE_MANAGER_ROLE = 410;

    /// @dev Managed by the Atomist
    uint64 public constant WHITELIST_DEPOSIT_ROLE = 1000;

    uint64 public constant PUBLIC_ROLE = type(uint64).max;
}

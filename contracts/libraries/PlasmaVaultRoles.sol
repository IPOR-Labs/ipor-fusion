// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

/// @title Predefined roles used in the PlasmaVault contract and its perypheral contracts (managers, fuses, etc.)
/// @notice For documentation purposes: When new roles are added by authorized property of PlasmaVault during runtime, they should be added and described here as well.
library PlasmaVaultRoles {
    /// @dev Managed by the Admin
    uint64 public constant ADMIN_ROLE = 0;

    /// @dev Managed by the Owner
    uint64 public constant OWNER_ROLE = 1;

    /// @dev Managed by the Owner
    uint64 public constant GUARDIAN_ROLE = 2;

    /// @dev Managed by Owner
    uint64 public constant ATOMIST_ROLE = 100;

    /// @dev Managed by the Atomist
    uint64 public constant ALPHA_ROLE = 200;

    /// @dev Managed by the Atomist
    uint64 public constant FUSE_MANAGER_ROLE = 300;

    /// @dev Managed by the Atomist
    uint64 public constant PERFORMANCE_FEE_MANAGER_ROLE = 400;

    /// @dev Managed by the Atomist
    uint64 public constant MANAGEMENT_FEE_MANAGER_ROLE = 500;

    /// @dev Managed by the Atomist
    uint64 public constant WHITELIST_DEPOSIT_ROLE = 600;

    uint64 public constant PUBLIC_ROLE = type(uint64).max;
}

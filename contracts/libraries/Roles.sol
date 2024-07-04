// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

/// @title Predefined roles used in the IPOR Fusion protocol
/// @notice For documentation purposes: When new roles are added by authorized property of PlasmaVault during runtime, they should be added and described here as well.
library Roles {
    /// @dev Managed by the Admin, the highest role from AccessManager
    uint64 public constant ADMIN_ROLE = 0;

    /// @dev Managed by the Owner, if applicable managed by the Admin
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
    uint64 public constant CLAIM_REWARDS_ROLE = 600;

    /// @dev Could be assigned only on bootstrap, this value could not be change after initialization
    uint64 public constant REWARDS_CLAIM_MANAGER_ROLE = 601;

    /// @dev Managed by the Atomist
    uint64 public constant TRANSFER_REWARDS_ROLE = 700;

    /// @dev Managed by the Atomist
    uint64 public constant WHITELIST_ROLE = 800;

    /// @dev Managed by the Atomist
    uint64 public constant CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE = 900;

    uint64 public constant PUBLIC_ROLE = type(uint64).max;
}

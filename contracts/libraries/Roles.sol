// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/**
 * @title Predefined roles used in the IPOR Fusion protocol
 * @notice For documentation purposes: When new roles are added by authorized property of PlasmaVault during runtime, they should be added and described here as well.
 * @dev Roles prefixed with 'TECH_' are special system roles that can only be assigned to and executed by contracts within the PlasmaVault ecosystem.
 * These technical roles are typically set during system initialization and cannot be reassigned during runtime.
 */
library Roles {
    /// @notice Account with this role has rights to manage the IporFusionAccessManager in general. The highest role, which could manage all roles including ADMIN_ROLE and OWNER_ROLE. It recommended to use MultiSig contract for this role.
    /// @dev Managed by the Admin, the highest role from AccessManager
    uint64 public constant ADMIN_ROLE = 0;

    /// @notice Account with this role has rights to manage Owners, Guardians, Atomists. It recommended to use MultiSig contract for this role.
    /// @dev Managed by the Owner, if applicable managed by the Admin
    uint64 public constant OWNER_ROLE = 1;

    /// @notice Account with this role has rights to cancel time-locked operations, pause restricted methods in PlasmaVault contracts in case of emergency
    /// @dev Managed by the Owner
    uint64 public constant GUARDIAN_ROLE = 2;

    /// @notice Technical role to limit access to methods only from the PlasmaVault contract
    /// @dev System role that can only be assigned to PlasmaVault contracts. Set during initialization and cannot be changed afterward
    uint64 public constant TECH_PLASMA_VAULT_ROLE = 3;

    /// @notice Technical role for IPOR DAO operations
    /// @dev System role that can only be assigned to IPOR DAO contract. Set during initialization and cannot be changed afterward
    uint64 public constant IPOR_DAO_ROLE = 4;

    /// @notice Technical role to limit access to methods only from the ContextManager contract
    /// @dev System role that can only be assigned to ContextManager contract. Set during initialization and cannot be changed afterward
    uint64 public constant TECH_CONTEXT_MANAGER_ROLE = 5;

    /// @notice Technical role to limit access to methods only from the WithdrawManager contract
    /// @dev System role that can only be assigned to WithdrawManager contract. Set during initialization and cannot be changed afterward
    uint64 public constant TECH_WITHDRAW_MANAGER_ROLE = 6;

    /// @notice Account with this role has rights to manage the PlasmaVault. It recommended to use MultiSig contract for this role.
    /// @dev Managed by Owner
    uint64 public constant ATOMIST_ROLE = 100;

    /// @notice Account with this role has rights to execute the alpha strategy on the PlasmaVault using execute method.
    /// @dev Managed by the Atomist
    uint64 public constant ALPHA_ROLE = 200;

    /// @notice Account with this role has rights to manage the FuseManager contract, add or remove fuses, balance fuses and reward fuses
    /// @dev Managed by the Atomist
    uint64 public constant FUSE_MANAGER_ROLE = 300;

    /// @notice Technical role for the FeeManager contract's performance fee operations
    /// @dev System role that can only be assigned to FeeManager contract. Set during initialization and cannot be changed afterward
    uint64 public constant TECH_PERFORMANCE_FEE_MANAGER_ROLE = 400;

    /// @notice Technical role for the FeeManager contract's management fee operations
    /// @dev System role that can only be assigned to FeeManager contract. Set during initialization and cannot be changed afterward
    uint64 public constant TECH_MANAGEMENT_FEE_MANAGER_ROLE = 500;

    /// @notice Account with this role has rights to claim rewards from the PlasmaVault using and interacting with the RewardsClaimManager contract
    /// @dev Managed by the Atomist
    uint64 public constant CLAIM_REWARDS_ROLE = 600;

    /// @notice Technical role for the RewardsClaimManager contract
    /// @dev System role that can only be assigned to RewardsClaimManager contract. Set during initialization and cannot be changed afterward
    uint64 public constant TECH_REWARDS_CLAIM_MANAGER_ROLE = 601;

    /// @notice Account with this role has rights to transfer rewards from the PlasmaVault to the RewardsClaimManager
    /// @dev Managed by the Atomist
    uint64 public constant TRANSFER_REWARDS_ROLE = 700;

    /// @notice Account with this role has rights to deposit / mint and withdraw / redeem assets from the PlasmaVault
    /// @dev Managed by the Atomist
    uint64 public constant WHITELIST_ROLE = 800;

    /// @notice Account with this role has rights to configure instant withdrawal fuses order.
    /// @dev Managed by the Atomist
    uint64 public constant CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE = 900;

    /// @notice Public role, no restrictions
    uint64 public constant PUBLIC_ROLE = type(uint64).max;
}

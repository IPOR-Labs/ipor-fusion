// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {RewardsRouter} from "../managers/rewards/RewardsRouter.sol";

/// @title RewardsRouterFactory
/// @notice Factory that deploys standalone per-vault {RewardsRouter} instances, tagging each with an
/// auto-incrementing index.
/// @dev Non-upgradeable and permissionless. A freshly deployed router is inert until the vault's ATOMIST
/// grants the rewards roles (CLAIM_REWARDS_ROLE, TRANSFER_REWARDS_ROLE, UPDATE_REWARDS_BALANCE_ROLE) to the
/// router (so it can drive the RewardsClaimManager) and ALPHA_ROLE to the alpha/keeper that will call
/// {RewardsRouter.execute}.
contract RewardsRouterFactory {
    /// @notice The index the next {create} call will assign (also the number of routers created so far).
    uint256 public nextIndex;

    /// @notice All {RewardsRouter} instances created for a given PlasmaVault, in creation order.
    /// @dev Keyed by the PlasmaVault the router is bound to. The auto-generated getter returns a single
    /// element by index (`routers(vault, i)`); use {getRouter} for the current (latest) router.
    mapping(address plasmaVault => address[] rewardsRouters) public routers;

    /// @notice Emitted when a new RewardsRouter is created.
    /// @param index The auto-incremented index assigned to this instance (off-chain bookkeeping only).
    /// @param router The address of the newly deployed router.
    /// @param plasmaVault The PlasmaVault the router is bound to.
    /// @param accessManager The access manager the router is bound to.
    event RewardsRouterCreated(uint256 index, address router, address plasmaVault, address accessManager);

    /// @notice Deploys a new standalone RewardsRouter bound to `plasmaVault_`.
    /// @param plasmaVault_ The PlasmaVault to bind the router to.
    /// @return router The address of the newly deployed router.
    function create(address plasmaVault_) external returns (address router) {
        RewardsRouter instance = new RewardsRouter(plasmaVault_);
        router = address(instance);

        routers[plasmaVault_].push(router);

        emit RewardsRouterCreated(nextIndex++, router, plasmaVault_, instance.ACCESS_MANAGER());
    }

    /// @notice Returns the current (most recently created) {RewardsRouter} for `plasmaVault_`.
    /// @param plasmaVault_ The PlasmaVault to look up.
    /// @return The latest router bound to `plasmaVault_`, or `address(0)` if none were created.
    function getRouter(address plasmaVault_) external view returns (address) {
        address[] storage vaultRouters = routers[plasmaVault_];
        uint256 len = vaultRouters.length;
        return len == 0 ? address(0) : vaultRouters[len - 1];
    }
}

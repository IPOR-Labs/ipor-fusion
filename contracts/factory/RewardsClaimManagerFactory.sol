// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {RewardsClaimManager} from "../managers/rewards/RewardsClaimManager.sol";

/// @title RewardsClaimManagerFactory
/// @notice Factory contract for creating RewardsClaimManager instances
contract RewardsClaimManagerFactory {
    /// @notice Emitted when a new RewardsClaimManager is created
    event RewardsClaimManagerCreated(address indexed manager, address indexed plasmaVault);

    /// @notice Creates a new RewardsClaimManager
    /// @param accessManager_ The initial authority address for access control
    /// @param plasmaVault_ Address of the plasma vault
    /// @return Address of the newly created RewardsClaimManager
    function createRewardsClaimManager(address accessManager_, address plasmaVault_) external returns (address) {
        RewardsClaimManager manager = new RewardsClaimManager(accessManager_, plasmaVault_);

        emit RewardsClaimManagerCreated(address(manager), plasmaVault_);
        return address(manager);
    }
}

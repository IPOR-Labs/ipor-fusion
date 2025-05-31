// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {RewardsClaimManager} from "../managers/rewards/RewardsClaimManager.sol";

/// @title RewardsClaimManagerFactory
/// @notice Factory contract for creating RewardsClaimManager instances
contract RewardsManagerFactory {
    event RewardsManagerCreated(address rewardsManager, address accessManager, address plasmaVault);

    /// @param accessManager_ The initial authority address for access control
    /// @param plasmaVault_ Address of the plasma vault
    /// @return rewardsManager Address of the newly created RewardsClaimManager
    function getInstance(address accessManager_, address plasmaVault_) external returns (address rewardsManager) {
        rewardsManager = address(new RewardsClaimManager(accessManager_, plasmaVault_));
        emit RewardsManagerCreated(rewardsManager, accessManager_, plasmaVault_);
    }
}

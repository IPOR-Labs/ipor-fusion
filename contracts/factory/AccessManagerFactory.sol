// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IporFusionAccessManager} from "../managers/access/IporFusionAccessManager.sol";

/// @title AccessManagerFactory
/// @notice Factory contract for creating and deploying new instances of IporFusionAccessManager
/// @dev This factory pattern allows for standardized creation of access management contracts
/// with configurable parameters for initial authority and redemption delay
contract AccessManagerFactory {
    /// @notice Emitted when a new AccessManager is created
    /// @param index The index of the AccessManager instance
    /// @param accessManager The address of the newly deployed IporFusionAccessManager contract
    /// @param redemptionDelayInSeconds The configured redemption delay in seconds for the new instance
    event AccessManagerCreated(uint256 index, address accessManager, uint256 redemptionDelayInSeconds);

    /// @notice Creates and deploys a new instance of IporFusionAccessManager
    /// @param index_ The index of the AccessManager instance
    /// @param initialAuthority_ The address that will have initial authority over the access manager
    /// @param redemptionDelayInSeconds_ The time delay in seconds required before redemption operations
    /// @return accessManager The address of the newly deployed IporFusionAccessManager contract
    function create(
        uint256 index_,
        address initialAuthority_,
        uint256 redemptionDelayInSeconds_
    ) external returns (address accessManager) {
        accessManager = address(new IporFusionAccessManager(initialAuthority_, redemptionDelayInSeconds_));
        emit AccessManagerCreated(index_, accessManager, redemptionDelayInSeconds_);
    }
}

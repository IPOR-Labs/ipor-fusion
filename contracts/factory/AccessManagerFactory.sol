// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IporFusionAccessManager} from "../managers/access/IporFusionAccessManager.sol";

/// @title AccessManagerFactory
/// @notice Factory contract for creating AccessManager instances
contract AccessManagerFactory {
    /// @notice Emitted when a new AccessManager is created
    event AccessManagerCreated(address accessManager, uint256 redemptionDelayInSeconds);

    /// @notice Creates a new IporFusionAccessManager
    /// @return accessManager Address of the newly created IporFusionAccessManager
    function getInstance(
        address initialAuthority_,
        uint256 redemptionDelayInSeconds_
    ) external returns (address accessManager) {
        accessManager = address(new IporFusionAccessManager(initialAuthority_, redemptionDelayInSeconds_));
        emit AccessManagerCreated(accessManager, redemptionDelayInSeconds_);
    }
}

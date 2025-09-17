// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IporFusionAccessManager} from "../managers/access/IporFusionAccessManager.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

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

    /// @notice Emitted when a new AccessManager instance is cloned
    /// @param baseAddress The address of the base AccessManager implementation to clone
    /// @param index The index of the AccessManager instance
    /// @param accessManager The address of the newly cloned IporFusionAccessManager contract
    /// @param redemptionDelayInSeconds The configured redemption delay in seconds for the new instance
    event AccessManagerCloned(
        address baseAddress,
        uint256 index,
        address accessManager,
        uint256 redemptionDelayInSeconds
    );

    /// @notice Error thrown when trying to use zero address as base
    error InvalidBaseAddress();

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

    // / @notice Creates a new instance of IporFusionAccessManager using Clones pattern
    // / @dev Clones the base IporFusionAccessManager and initializes it with the provided parameters
    // / @param baseAddress_ The address of the base IporFusionAccessManager implementation to clone
    // / @param index_ The index of the AccessManager instance
    // / @param initialAuthority_ The address that will have initial authority over the access manager
    // / @param redemptionDelayInSeconds_ The time delay in seconds required before redemption operations
    // / @return accessManager The address of the newly cloned IporFusionAccessManager contract
    function clone(
        address baseAddress_,
        uint256 index_,
        address initialAuthority_,
        uint256 redemptionDelayInSeconds_
    ) external returns (address accessManager) {
        if (baseAddress_ == address(0)) revert InvalidBaseAddress();

        accessManager = Clones.clone(baseAddress_);
        IporFusionAccessManager(accessManager).proxyInitialize(initialAuthority_, redemptionDelayInSeconds_);

        emit AccessManagerCreated(index_, accessManager, redemptionDelayInSeconds_);
        emit AccessManagerCloned(baseAddress_, index_, accessManager, redemptionDelayInSeconds_);
    }

}

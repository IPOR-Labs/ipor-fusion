// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IporFusionAccessManager} from "../managers/access/IporFusionAccessManager.sol";

/// @title IporFusionAccessManagerFactory
/// @notice Factory contract for creating IporFusionAccessManager instances
contract IporFusionAccessManagerFactory {
    /// @notice Emitted when a new IporFusionAccessManager is created
    event IporFusionAccessManagerCreated(address indexed manager);

    /// @notice Creates a new IporFusionAccessManager
    /// @return Address of the newly created IporFusionAccessManager
    function createIporFusionAccessManager(
        address initialAuthority_
    ) external returns (address) {
        IporFusionAccessManager manager = new IporFusionAccessManager(initialAuthority_, 1);
        emit IporFusionAccessManagerCreated(address(manager));
        return address(manager);
    }
}

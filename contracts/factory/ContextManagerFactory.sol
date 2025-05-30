// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ContextManager} from "../managers/context/ContextManager.sol";

/// @title ContextManagerFactory
/// @notice Factory contract for creating ContextManager instances
contract ContextManagerFactory {
    event ContextManagerCreated(address contextManager);

    /// @notice Creates a new ContextManager
    /// @param accessManager_ The initial authority address for access control
    /// @param approvedTargets_ The addresses of the approved targets
    /// @return contextManager Address of the newly created ContextManager
    function getInstance(
        address accessManager_,
        address[] memory approvedTargets_
    ) external returns (address contextManager) {
        contextManager = address(new ContextManager(accessManager_, approvedTargets_));
        emit ContextManagerCreated(contextManager);
    }
}

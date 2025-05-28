// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ContextManager} from "../managers/context/ContextManager.sol";

/// @title ContextManagerFactory
/// @notice Factory contract for creating ContextManager instances
contract ContextManagerFactory {
    /// @notice Emitted when a new ContextManager is created
    event ContextManagerCreated(address indexed manager);

    /// @notice Creates a new ContextManager
    /// @param accessManager_ The initial authority address for access control
    /// @return Address of the newly created ContextManager
    function createContextManager(address accessManager_, address[] memory approvedTargets_) external returns (address) {
        ContextManager manager = new ContextManager(accessManager_, approvedTargets_);

        emit ContextManagerCreated(address(manager));

        return address(manager);
    }
}

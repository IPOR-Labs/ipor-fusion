// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ContextManager} from "../managers/context/ContextManager.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

/// @title ContextManagerFactory
/// @notice Factory contract for creating ContextManager instances that manage execution context and permissions for vault operations
contract ContextManagerFactory {
    /// @notice Emitted when a new ContextManager instance is created
    /// @param index The index of the ContextManager instance
    /// @param contextManager The address of the newly created ContextManager
    /// @param approvedTargets The addresses of the approved targets
    event ContextManagerCreated(uint256 index, address contextManager, address[] approvedTargets);

    /// @notice Emitted when a new ContextManager instance is cloned
    /// @param baseAddress The address of the base ContextManager implementation to clone
    /// @param index The index of the ContextManager instance
    /// @param contextManager The address of the newly cloned ContextManager
    /// @param approvedTargets The addresses of the approved targets
    event ContextManagerCloned(address baseAddress, uint256 index, address contextManager, address[] approvedTargets);

    /// @notice Error thrown when trying to use zero address as base
    error InvalidBaseAddress();

    /// @notice Creates a new ContextManager
    /// @param index_ The index of the ContextManager instance
    /// @param accessManager_ The initial authority address for access control
    /// @param approvedTargets_ The addresses of the approved targets
    /// @return contextManager Address of the newly created ContextManager
    function create(
        uint256 index_,
        address accessManager_,
        address[] memory approvedTargets_
    ) external returns (address contextManager) {
        contextManager = address(new ContextManager(accessManager_, approvedTargets_));
        emit ContextManagerCreated(index_, contextManager, approvedTargets_);
    }

    /// @notice Creates a new instance of ContextManager using Clones pattern
    /// @param baseAddress_ The address of the base ContextManager implementation to clone
    /// @param index_ The index of the ContextManager instance
    /// @param accessManager_ The initial authority address for access control
    /// @param approvedTargets_ The addresses of the approved targets
    /// @return contextManager Address of the newly cloned ContextManager
    function clone(
        address baseAddress_,
        uint256 index_,
        address accessManager_,
        address[] memory approvedTargets_
    ) external returns (address contextManager) {
        if (baseAddress_ == address(0)) revert InvalidBaseAddress();

        contextManager = Clones.clone(baseAddress_);
        ContextManager(contextManager).proxyInitialize(accessManager_, approvedTargets_);
        
        emit ContextManagerCreated(index_, contextManager, approvedTargets_);
        emit ContextManagerCloned(baseAddress_, index_, contextManager, approvedTargets_);
    }
}

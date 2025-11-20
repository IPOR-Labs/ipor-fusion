// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

/// @title FuseWhitelistAccessControl
/// @notice Access control for FuseWhitelist contract
/// @dev Implements role-based access control for fuse management
abstract contract FuseWhitelistAccessControl is AccessControlEnumerableUpgradeable {
    /// @notice Role for managing fuse types
    /// @dev Protects:
    /// - addFuseTypes()
    bytes32 public constant FUSE_TYPE_MANAGER_ROLE = keccak256("FUSE_TYPE_MANAGER_ROLE");

    /// @notice Role for managing fuse states
    /// @dev Protects:
    /// - addFuseStates()
    bytes32 public constant FUSE_STATE_MANAGER_ROLE = keccak256("FUSE_STATE_MANAGER_ROLE");

    /// @notice Role for managing metadata types
    /// @dev Protects:
    /// - addMetadataTypes()
    bytes32 public constant FUSE_METADATA_MANAGER_ROLE = keccak256("FUSE_METADATA_MANAGER_ROLE");

    /// @notice Role for adding new fuses to the system
    /// @dev Protects:
    /// - addFuses()
    bytes32 public constant ADD_FUSE_MANAGER_ROLE = keccak256("ADD_FUSE_MANAGER_ROLE");

    /// @notice Role for updating fuse states
    /// @dev Protects:
    /// - updateFuseState()
    bytes32 public constant UPDATE_FUSE_STATE_MANAGER_ROLE = keccak256("UPDATE_FUSE_STATE_MANAGER_ROLE");

    /// @notice Role for updating fuse types
    /// @dev Protects:
    /// - updateFuseType()
    bytes32 public constant UPDATE_FUSE_TYPE_MANAGER_ROLE = keccak256("UPDATE_FUSE_TYPE_MANAGER_ROLE");

    /// @notice Role for updating fuse metadata
    /// @dev Protects:
    /// - updateFuseMetadata()
    bytes32 public constant UPDATE_FUSE_METADATA_MANAGER_ROLE = keccak256("UPDATE_FUSE_METADATA_MANAGER_ROLE");

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the access control system
    /// @dev Grants the deployer the default admin role
    /// @dev This function can only be called once through the proxy's constructor
    function __IporFusionAccessControl_init() internal onlyInitializing {
        __AccessControlEnumerable_init();
        __IporFusionAccessControl_init_unchained();
    }

    /// @notice Unchained initialization function
    /// @dev Used for additional initialization logic if needed
    function __IporFusionAccessControl_init_unchained() internal onlyInitializing {}
}

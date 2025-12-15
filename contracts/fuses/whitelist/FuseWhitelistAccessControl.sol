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
    /// @dev Value: 0x8aeb4bdd05ee74116d5903a8b120d6a022dc729e37b03bf522b0d9f7d62a7dfd
    bytes32 public constant FUSE_TYPE_MANAGER_ROLE = keccak256("FUSE_TYPE_MANAGER_ROLE");

    /// @notice Role for managing fuse states
    /// @dev Protects:
    /// - addFuseStates()
    /// @dev Value: 0x75c1f71cc6d461a46fd8c7abd959cd0b64785ccd7469a8b0e4e0d68747cf0bb4
    bytes32 public constant FUSE_STATE_MANAGER_ROLE = keccak256("FUSE_STATE_MANAGER_ROLE");

    /// @notice Role for managing metadata types
    /// @dev Protects:
    /// - addMetadataTypes()
    /// @dev Value: 0xac13ce08f612d078262da0e094a923b82c0b4b46b5238a042d2ddc0ed5ead73c
    bytes32 public constant FUSE_METADATA_MANAGER_ROLE = keccak256("FUSE_METADATA_MANAGER_ROLE");

    /// @notice Role for adding new fuses to the system
    /// @dev Protects:
    /// - addFuses()
    /// @dev Value: 0xbb30e7e32e0cbb0f754c883f17a5bfd8085280f855aefef50110f70bd40cb28e
    bytes32 public constant ADD_FUSE_MANAGER_ROLE = keccak256("ADD_FUSE_MANAGER_ROLE");

    /// @notice Role for updating fuse states
    /// @dev Protects:
    /// - updateFuseState()
    /// @dev Value: 0x4fb3bb34cb42e4219dee290bc397df1e4bcf56558ff09c87044cd8f9addd5c48
    bytes32 public constant UPDATE_FUSE_STATE_MANAGER_ROLE = keccak256("UPDATE_FUSE_STATE_MANAGER_ROLE");

    /// @notice Role for updating fuse types
    /// @dev Protects:
    /// - updateFuseType()
    /// @dev Value: 0x401c05f24952f3bd2877c78ba28fdbc5d639b12726530f8106523a21a41e4c2e
    bytes32 public constant UPDATE_FUSE_TYPE_MANAGER_ROLE = keccak256("UPDATE_FUSE_TYPE_MANAGER_ROLE");

    /// @notice Role for updating fuse metadata
    /// @dev Protects:
    /// - updateFuseMetadata()
    /// @dev Value: 0x94e00ed32d433fb9f4b53e166f06c01a3dc963d5ebf4d27d007284ab0e528b46
    bytes32 public constant UPDATE_FUSE_METADATA_MANAGER_ROLE = keccak256("UPDATE_FUSE_METADATA_MANAGER_ROLE");

    /// @notice Role for updating fuse deployment timestamps
    /// @dev Protects:
    /// - updateFuseDeploymentTimestamp()
    /// - updateFusesDeploymentTimestamps()
    /// @dev Value: 0xa10a1d1cb60f17dbaf7e7efcd6b94eecd77627eaea5b806e22b486fe25c045aa
    bytes32 public constant UPDATE_FUSE_DEPLOYMENT_TIMESTAMP_MANAGER_ROLE =
        keccak256("UPDATE_FUSE_DEPLOYMENT_TIMESTAMP_MANAGER_ROLE");

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

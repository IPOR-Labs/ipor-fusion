// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

abstract contract FuseWhitelistAccessControl is AccessControlEnumerableUpgradeable {
    /// @notice Role that allows adding fuse types
    bytes32 public constant CONFIGURATION_MANAGER_ROLE = keccak256("CONFIGURATION_MANAGER_ROLE");
    /// @notice Role that allows adding fuse states
    bytes32 public constant ADD_FUSE_MENAGER_ROLE = keccak256("ADD_FUSE_MENAGER_ROLE");
    bytes32 public constant UPDATE_FUSE_STATE_ROLE = keccak256("UPDATE_FUSE_STATE_ROLE");
    bytes32 public constant UPDATE_FUSE_METADATA_ROLE = keccak256("UPDATE_FUSE_METADATA_ROLE");

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the contract granting the deployer the default admin role.
     * This function can only be called once through the proxy's constructor.
     */
    function __IporFusionAccessControl_init() internal onlyInitializing {
        __AccessControlEnumerable_init();
        __IporFusionAccessControl_init_unchained();
    }

    function __IporFusionAccessControl_init_unchained() internal onlyInitializing {}
}

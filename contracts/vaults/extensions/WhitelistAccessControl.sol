// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

/**
 * @title WhitelistAccessControl
 * @dev Contract for managing whitelist access control in the IPOR Fusion system.
 * Inherits from AccessControlEnumerableUpgradeable to provide role-based access control with enumeration capabilities.
 */
abstract contract WhitelistAccessControl is AccessControlEnumerableUpgradeable {
    /// @notice Role that allows being whitelisted
    /// @dev bytes32 - 0xe799c73ff785ac053943f5d98452f7fa0bcf54da67826fc217d6094dec75c5ee
    bytes32 public constant WHITELISTED = keccak256("WHITELISTED");

    /// @notice Role that allows managing whitelist (adding/removing whitelisted addresses)
    /// @dev bytes32 - 0x827de50cc5532fcea9338402dc65442c2567a37fbd0cd8eb56858d00e9e842bd
    bytes32 public constant WHITELIST_MANAGER = keccak256("WHITELIST_MANAGER");

    error ZeroAdminAddress();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address initialAdmin_) {
        if (initialAdmin_ == address(0)) revert ZeroAdminAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin_);
        _setRoleAdmin(WHITELIST_MANAGER, DEFAULT_ADMIN_ROLE);
        _setRoleAdmin(WHITELISTED, WHITELIST_MANAGER);
        _disableInitializers();
    }
}

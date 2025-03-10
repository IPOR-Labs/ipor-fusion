// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

/**
 * @title IporFusionAccessControl
 * @dev Abstract contract for managing access control in the IPOR Fusion system.
 * Inherits from AccessControlEnumerableUpgradeable to provide role-based access control with enumeration capabilities.
 */
abstract contract IporFusionAccessControl is AccessControlEnumerableUpgradeable {
    /// @notice Role that allows adding PT token prices
    bytes32 public constant ADD_PT_TOKEN_PRICE = keccak256("ADD_PT_TOKEN_PRICE");
    bytes32 public constant SET_ASSETS_PRICES_SOURCES = keccak256("SET_ASSETS_PRICES_SOURCES");

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

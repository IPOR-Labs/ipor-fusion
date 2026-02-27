// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

/**
 * @title IporFusionAccessControl
 * @dev Abstract contract for managing access control in the IPOR Fusion system.
 * Inherits from AccessControlEnumerableUpgradeable to provide role-based access control with enumeration capabilities.
 */
abstract contract IporFusionAccessControl is AccessControlEnumerableUpgradeable {
    /// @notice Role that allows adding PT token prices
    /// @dev bytes32 - 0x7bbd1fd432aa686d83eaff2e940b6d3b56e45b893444614ca341987f14379c7d
    bytes32 public constant ADD_PT_TOKEN_PRICE = keccak256("ADD_PT_TOKEN_PRICE");

    /// @notice Role that allows setting assets prices sources
    /// @dev bytes32 - 0x58fb5220de46b94ead43a7c850443ec6b00bec9e9e2a8741abda98af086ec957
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

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

abstract contract FusionFactoryAccessControl is AccessControlEnumerableUpgradeable {

    /// @notice Role for maintenance manager
    bytes32 public constant MAINTENANCE_MANAGER_ROLE = keccak256("MAINTENANCE_MANAGER_ROLE");

    bytes32 public constant PAUSE_MANAGER_ROLE = keccak256("PAUSE_MANAGER_ROLE");

    /// @notice Role for managing DAO fee configuration
    /// @dev Protects:
    /// - updateIporDaoFee()
    bytes32 public constant DAO_FEE_MANAGER_ROLE = keccak256("DAO_FEE_MANAGER_ROLE");

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function __FusionFactoryAccessControl_init() internal onlyInitializing {
        __AccessControlEnumerable_init();
    }
}

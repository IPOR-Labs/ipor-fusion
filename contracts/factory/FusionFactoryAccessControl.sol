// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/extensions/AccessControlEnumerableUpgradeable.sol";

abstract contract FusionFactoryAccessControl is AccessControlEnumerableUpgradeable {
    /// @notice Role for maintenance manager
    /// @dev Protects:
    /// - updateFactoryAddresses()
    /// - updatePlasmaVaultBase()
    /// - updatePriceOracleMiddleware()
    /// - updateBurnRequestFeeFuse()
    /// - updateBurnRequestFeeBalanceFuse()
    /// - updateRedemptionDelayInSeconds()
    /// - updateWithdrawWindowInSeconds()
    /// - updateVestingPeriodInSeconds()
    /// @dev 0xc92702f3c63b30841ab26169cbd31cea991bdf14238d5ef7a0d75d105d494d30
    bytes32 public constant MAINTENANCE_MANAGER_ROLE = keccak256("MAINTENANCE_MANAGER_ROLE");

    /// @notice Role for pausing the factory
    /// @dev Protects:
    /// - pause()
    /// - unpause()
    /// @dev 0x356a809dfdea9198dd76fb76bf6d403ecf13ea675eb89e1eda2db2c4a4676a26
    bytes32 public constant PAUSE_MANAGER_ROLE = keccak256("PAUSE_MANAGER_ROLE");

    /// @notice Role for managing DAO fee configuration
    /// @dev 0x12ca4a5ac2cad705272a39c92e45caa2d9c303ba57e709eab1ff20b24512e266
    /// @dev Protects:
    /// - updateIporDaoFee()
    bytes32 public constant DAO_FEE_MANAGER_ROLE = keccak256("DAO_FEE_MANAGER_ROLE");

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // solhint-disable-next-line func-name-mixedcase
    function __FusionFactoryAccessControl_init() internal onlyInitializing {
        __AccessControlEnumerable_init();
    }
}

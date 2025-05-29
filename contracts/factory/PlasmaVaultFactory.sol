// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PlasmaVaultInitData} from "../vaults/PlasmaVault.sol";
import {PlasmaVault} from "../vaults/PlasmaVault.sol";

/// @title PlasmaVaultFactory
/// @notice Factory contract for creating PlasmaVault instances using minimal proxy pattern
contract PlasmaVaultFactory {
    /// @notice Emitted when a new PlasmaVault is created
    event PlasmaVaultCreated(address indexed vault, address indexed underlyingToken);

    /// @notice Creates a new PlasmaVault using minimal proxy pattern
    /// @param initData_ The initialization data for the PlasmaVault
    /// @return Address of the newly created PlasmaVault
    function createPlasmaVault(PlasmaVaultInitData memory initData_) external returns (address) {
        // Deploy new PlasmaVault instance
        address vault = address(new PlasmaVault(initData_));

        emit PlasmaVaultCreated(vault, initData_.underlyingToken);

        return vault;
    }
}

interface IPlasmaVault {
    function initialize(PlasmaVaultInitData memory initData_) external;
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PlasmaVaultInitData} from "../vaults/PlasmaVault.sol";
import {PlasmaVault} from "../vaults/PlasmaVault.sol";

/// @title PlasmaVaultFactory
/// @notice Factory contract for creating PlasmaVault instances using minimal proxy pattern
contract PlasmaVaultFactory {
    event PlasmaVaultCreated(address plasmaVault, string assetName, string assetSymbol, address underlyingToken);

    /// @notice Creates a new PlasmaVault using minimal proxy pattern
    /// @param initData_ The initialization data for the PlasmaVault
    /// @return plasmaVault Address of the newly created PlasmaVault
    function getInstance(PlasmaVaultInitData memory initData_) external returns (address plasmaVault) {
        plasmaVault = address(new PlasmaVault(initData_));
        emit PlasmaVaultCreated(plasmaVault, initData_.assetName, initData_.assetSymbol, initData_.underlyingToken);
    }
}

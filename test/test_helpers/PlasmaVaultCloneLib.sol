// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";

/// @title PlasmaVaultCloneLib
/// @notice Test helper that creates PlasmaVault instances the way production does: as minimal proxy clones.
/// @dev IL-8979: the PlasmaVault implementation contract must not be initializable, so tests cannot call
///      `proxyInitialize` on a freshly deployed implementation. Production vaults are clones created by
///      `PlasmaVaultFactory.clone`, and tests use the same path through this library.
library PlasmaVaultCloneLib {
    /// @notice Deploys a fresh PlasmaVault implementation and returns an uninitialized clone of it.
    /// @dev The returned clone is ready for a single `proxyInitialize` call. The implementation stays uninitialized.
    /// @return plasmaVault The uninitialized PlasmaVault clone
    function newPlasmaVault() internal returns (PlasmaVault plasmaVault) {
        plasmaVault = clone(address(new PlasmaVault()));
    }

    /// @notice Returns an uninitialized clone of an already deployed PlasmaVault implementation.
    /// @dev Use for implementations created with `vm.deployCode("PlasmaVault.sol:PlasmaVault")`.
    /// @param implementation_ Address of the PlasmaVault implementation
    /// @return plasmaVault The uninitialized PlasmaVault clone
    function clone(address implementation_) internal returns (PlasmaVault plasmaVault) {
        plasmaVault = PlasmaVault(Clones.clone(implementation_));
    }
}

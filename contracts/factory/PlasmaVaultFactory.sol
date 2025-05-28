// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PlasmaVaultInitData} from "../vaults/PlasmaVault.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";


/// @title PlasmaVaultFactory
/// @notice Factory contract for creating PlasmaVault instances using minimal proxy pattern
contract PlasmaVaultFactory {
    /// @notice Emitted when a new PlasmaVault is created
    event PlasmaVaultCreated(address indexed vault, address indexed underlyingToken);

    /// @notice The implementation contract address
    address public immutable implementation;

    /// @notice Constructor that deploys the implementation contract
    constructor(address implementation_) {
        implementation = implementation_;
    }

    /// @notice Creates a new PlasmaVault using minimal proxy pattern
    /// @param initData_ The initialization data for the PlasmaVault
    /// @return Address of the newly created PlasmaVault
    function createPlasmaVault(PlasmaVaultInitData memory initData_) external returns (address) {
        address clone = Clones.clone(implementation);
        IPlasmaVault(clone).initialize(initData_);
        emit PlasmaVaultCreated(clone, initData_.underlyingToken);
        return clone;
    }
}

interface IPlasmaVault {
    function initialize(PlasmaVaultInitData memory initData_) external;
}


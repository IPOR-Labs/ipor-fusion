// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {WrappedPlasmaVault} from "../../vaults/extensions/WrappedPlasmaVault.sol";

/// @title WrappedPlasmaVaultFactory
/// @notice Factory contract for creating wrapped plasma vaults
/// @dev This contract is upgradeable and uses UUPS pattern for upgrades
contract WrappedPlasmaVaultFactory is UUPSUpgradeable, Ownable2StepUpgradeable {
    /// @notice Error thrown when an invalid address (zero address) is provided
    error InvalidAddress();

    /// @notice Emitted when a new wrapped plasma vault is created
    /// @param name The name of the wrapped plasma vault
    /// @param symbol The symbol of the wrapped plasma vault
    /// @param plasmaVault The address of the underlying plasma vault
    /// @param wrappedPlasmaVaultOwner The address of the owner of the wrapped plasma vault
    event WrappedPlasmaVaultCreated(
        string name,
        string symbol,
        address plasmaVault,
        address wrappedPlasmaVaultOwner,
        address wrappedPlasmaVault
    );

    /// @notice Initializes the factory contract
    /// @dev This function can only be called once during contract deployment
    /// @param initialFactoryAdmin_ The address that will be set as the initial admin of the factory
    function initialize(address initialFactoryAdmin_) external initializer {
        if (initialFactoryAdmin_ == address(0)) revert InvalidAddress();
        __Ownable_init(initialFactoryAdmin_);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
    }

    function create(
        string memory name_,
        string memory symbol_,
        address plasmaVault_,
        address wrappedPlasmaVaultOwner_
    ) external returns (address wrappedPlasmaVault) {
        wrappedPlasmaVault = address(new WrappedPlasmaVault(name_, symbol_, plasmaVault_, wrappedPlasmaVaultOwner_));
        emit WrappedPlasmaVaultCreated(name_, symbol_, plasmaVault_, wrappedPlasmaVaultOwner_, wrappedPlasmaVault);
    }

    /// @notice Authorizes an upgrade to a new implementation
    /// @dev Required by the OZ UUPS module, can only be called by the owner
    /// @param newImplementation Address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

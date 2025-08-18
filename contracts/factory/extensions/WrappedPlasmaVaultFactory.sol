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
    /// @notice Error thrown when an invalid fee percentage is provided
    error InvalidFeePercentage();

    /// @notice Emitted when a new wrapped plasma vault is created
    /// @param name The name of the wrapped plasma vault
    /// @param symbol The symbol of the wrapped plasma vault
    /// @param plasmaVault The address of the underlying plasma vault
    /// @param wrappedPlasmaVaultOwner The address of the owner of the wrapped plasma vault
    /// @param wrappedPlasmaVault The address of the created wrapped plasma vault
    /// @param managementFeeAccount The address that will receive management fees
    /// @param managementFeePercentage The management fee percentage (10000 = 100%, 100 = 1%)
    /// @param performanceFeeAccount The address that will receive performance fees
    /// @param performanceFeePercentage The performance fee percentage (10000 = 100%, 100 = 1%)
    event WrappedPlasmaVaultCreated(
        string name,
        string symbol,
        address plasmaVault,
        address wrappedPlasmaVaultOwner,
        address wrappedPlasmaVault,
        address managementFeeAccount,
        uint256 managementFeePercentage,
        address performanceFeeAccount,
        uint256 performanceFeePercentage
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the factory contract
    /// @dev This function can only be called once during contract deployment
    /// @param initialFactoryAdmin_ The address that will be set as the initial admin of the factory
    function initialize(address initialFactoryAdmin_) external initializer {
        if (initialFactoryAdmin_ == address(0)) revert InvalidAddress();
        __Ownable_init(initialFactoryAdmin_);
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
    }

    /// @notice Creates a new wrapped plasma vault with fee configuration
    /// @param name_ The name of the wrapped plasma vault
    /// @param symbol_ The symbol of the wrapped plasma vault
    /// @param plasmaVault_ The address of the underlying plasma vault
    /// @param wrappedPlasmaVaultOwner_ The address of the owner of the wrapped plasma vault
    /// @param managementFeeAccount_ The address that will receive management fees
    /// @param managementFeePercentage_ The management fee percentage (10000 = 100%, 100 = 1%)
    /// @param performanceFeeAccount_ The address that will receive performance fees
    /// @param performanceFeePercentage_ The performance fee percentage (10000 = 100%, 100 = 1%)
    /// @return wrappedPlasmaVault The address of the created wrapped plasma vault
    function create(
        string memory name_,
        string memory symbol_,
        address plasmaVault_,
        address wrappedPlasmaVaultOwner_,
        address managementFeeAccount_,
        uint256 managementFeePercentage_,
        address performanceFeeAccount_,
        uint256 performanceFeePercentage_
    ) external returns (address wrappedPlasmaVault) {
        if (plasmaVault_ == address(0)) revert InvalidAddress();
        if (wrappedPlasmaVaultOwner_ == address(0)) revert InvalidAddress();

        if (managementFeeAccount_ == address(0)) revert InvalidAddress();
        if (performanceFeeAccount_ == address(0)) revert InvalidAddress();
        if (managementFeePercentage_ > 10000) revert InvalidFeePercentage();
        if (performanceFeePercentage_ > 10000) revert InvalidFeePercentage();

        wrappedPlasmaVault = address(
            new WrappedPlasmaVault(
                name_,
                symbol_,
                plasmaVault_,
                wrappedPlasmaVaultOwner_,
                managementFeeAccount_,
                managementFeePercentage_,
                performanceFeeAccount_,
                performanceFeePercentage_
            )
        );

        emit WrappedPlasmaVaultCreated(
            name_,
            symbol_,
            plasmaVault_,
            wrappedPlasmaVaultOwner_,
            wrappedPlasmaVault,
            managementFeeAccount_,
            managementFeePercentage_,
            performanceFeeAccount_,
            performanceFeePercentage_
        );
    }

    /// @notice Authorizes an upgrade to a new implementation
    /// @dev Required by the OZ UUPS module, can only be called by the owner
    /// @param newImplementation Address of the new implementation
    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

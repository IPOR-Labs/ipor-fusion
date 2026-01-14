// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {WhitelistWrappedPlasmaVault} from "../../vaults/extensions/WhitelistWrappedPlasmaVault.sol";

/// @title WhitelistWrappedPlasmaVaultFactory
/// @notice Factory contract for creating whitelist wrapped plasma vaults
/// @dev This contract is upgradeable and uses UUPS pattern for upgrades
contract WhitelistWrappedPlasmaVaultFactory is UUPSUpgradeable, Ownable2StepUpgradeable {
    /// @notice Error thrown when an invalid address (zero address) is provided
    error InvalidAddress();
    /// @notice Error thrown when an invalid fee percentage is provided
    error InvalidFeePercentage();

    /// @notice Emitted when a new whitelist wrapped plasma vault is created
    /// @param name The name of the whitelist wrapped plasma vault
    /// @param symbol The symbol of the whitelist wrapped plasma vault
    /// @param plasmaVault The address of the underlying plasma vault
    /// @param initialAdmin The address of the initial admin of the whitelist access control
    /// @param whitelistWrappedPlasmaVault The address of the created whitelist wrapped plasma vault
    /// @param managementFeeAccount The address that will receive management fees
    /// @param managementFeePercentage The management fee percentage (10000 = 100%, 100 = 1%)
    /// @param performanceFeeAccount The address that will receive performance fees
    /// @param performanceFeePercentage The performance fee percentage (10000 = 100%, 100 = 1%)
    event WhitelistWrappedPlasmaVaultCreated(
        string name,
        string symbol,
        address plasmaVault,
        address initialAdmin,
        address whitelistWrappedPlasmaVault,
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

    /// @notice Creates a new whitelist wrapped plasma vault with fee configuration
    /// @param name_ The name of the whitelist wrapped plasma vault
    /// @param symbol_ The symbol of the whitelist wrapped plasma vault
    /// @param plasmaVault_ The address of the underlying plasma vault
    /// @param initialAdmin_ The address of the initial admin of the whitelist access control
    /// @param managementFeeAccount_ The address that will receive management fees
    /// @param managementFeePercentage_ The management fee percentage (10000 = 100%, 100 = 1%)
    /// @param performanceFeeAccount_ The address that will receive performance fees
    /// @param performanceFeePercentage_ The performance fee percentage (10000 = 100%, 100 = 1%)
    /// @return whitelistWrappedPlasmaVault The address of the created whitelist wrapped plasma vault
    function create(
        string memory name_,
        string memory symbol_,
        address plasmaVault_,
        address initialAdmin_,
        address managementFeeAccount_,
        uint256 managementFeePercentage_,
        address performanceFeeAccount_,
        uint256 performanceFeePercentage_
    ) external returns (address whitelistWrappedPlasmaVault) {
        if (plasmaVault_ == address(0)) revert InvalidAddress();
        if (initialAdmin_ == address(0)) revert InvalidAddress();

        if (managementFeeAccount_ == address(0)) revert InvalidAddress();
        if (performanceFeeAccount_ == address(0)) revert InvalidAddress();
        if (managementFeePercentage_ > 10000) revert InvalidFeePercentage();
        if (performanceFeePercentage_ > 10000) revert InvalidFeePercentage();

        whitelistWrappedPlasmaVault = address(
            new WhitelistWrappedPlasmaVault(
                name_,
                symbol_,
                plasmaVault_,
                initialAdmin_,
                managementFeeAccount_,
                managementFeePercentage_,
                performanceFeeAccount_,
                performanceFeePercentage_
            )
        );

        emit WhitelistWrappedPlasmaVaultCreated(
            name_,
            symbol_,
            plasmaVault_,
            initialAdmin_,
            whitelistWrappedPlasmaVault,
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

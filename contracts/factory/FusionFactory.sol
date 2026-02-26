// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {FusionFactoryStorageLib} from "./lib/FusionFactoryStorageLib.sol";
import {VaultInstanceAddresses, Component} from "./lib/FusionFactoryStorageLib.sol";

import {FusionFactoryLogicLib} from "./lib/FusionFactoryLogicLib.sol";
import {FusionFactoryLib} from "./lib/FusionFactoryLib.sol";

import {FusionFactoryAccessControl} from "./FusionFactoryAccessControl.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IporFusionAccessManager} from "../managers/access/IporFusionAccessManager.sol";
import {Roles} from "../libraries/Roles.sol";

/// @title FusionFactory
/// @notice Factory contract for creating and managing Fusion Managers
/// @dev This contract is responsible for deploying and initializing various manager contracts
contract FusionFactory is UUPSUpgradeable, FusionFactoryAccessControl {
    event FactoryAddressesUpdated(
        uint256 version,
        address accessManagerFactory,
        address plasmaVaultFactory,
        address feeManagerFactory,
        address withdrawManagerFactory,
        address rewardsManagerFactory,
        address contextManagerFactory,
        address priceManagerFactory
    );

    event BaseAddressesUpdated(
        uint256 version,
        address newPlasmaVaultCoreBase,
        address newAccessManagerBase,
        address newPriceManagerBase,
        address newWithdrawManagerBase,
        address newRewardsManagerBase,
        address newContextManagerBase
    );

    event PlasmaVaultBaseUpdated(address newPlasmaVaultBase);
    event PriceOracleMiddlewareUpdated(address newPriceOracleMiddleware);
    event BurnRequestFeeFuseUpdated(address newBurnRequestFeeFuse);
    event BurnRequestFeeBalanceFuseUpdated(address newBurnRequestFeeBalanceFuse);
    event WithdrawWindowInSecondsUpdated(uint256 newWithdrawWindowInSeconds);
    event VestingPeriodInSecondsUpdated(uint256 newVestingPeriodInSeconds);
    event PlasmaVaultAdminArrayUpdated(address[] newPlasmaVaultAdminArray);
    event DaoFeePackagesUpdated(FusionFactoryStorageLib.FeePackage[] packages, address updatedBy);

    /// @notice Emitted when a vault instance is created with deterministic addresses
    /// @param masterSalt The master salt used for address derivation
    /// @param plasmaVault The address of the deployed PlasmaVault
    /// @param accessManager The address of the deployed AccessManager
    /// @param priceManager The address of the deployed PriceManager
    /// @param withdrawManager The address of the deployed WithdrawManager
    /// @param feeManager The address of the FeeManager (created by PlasmaVault.init)
    /// @param rewardsManager The pre-computed address of the RewardsManager
    /// @param contextManager The pre-computed address of the ContextManager
    event VaultInstanceCreatedDeterministic(
        bytes32 indexed masterSalt,
        address indexed plasmaVault,
        address accessManager,
        address priceManager,
        address withdrawManager,
        address feeManager,
        address rewardsManager,
        address contextManager
    );

    /// @notice Emitted when a Phase 2 component is deployed
    /// @param plasmaVault The address of the plasma vault
    /// @param component The component that was deployed
    /// @param deployedAddress The address of the deployed component
    event ComponentDeployed(address indexed plasmaVault, Component component, address deployedAddress);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address initialFactoryAdmin_,
        address[] memory initialPlasmaVaultAdminArray_,
        FusionFactoryStorageLib.FactoryAddresses memory factoryAddresses_,
        address plasmaVaultBase_,
        address priceOracleMiddleware_,
        address burnRequestFeeFuse_,
        address burnRequestFeeBalanceFuse_
    ) external initializer {
        __FusionFactoryAccessControl_init();
        __UUPSUpgradeable_init();

        if (initialFactoryAdmin_ == address(0)) revert FusionFactoryLib.InvalidAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, initialFactoryAdmin_);

        FusionFactoryLib.initialize(
            initialPlasmaVaultAdminArray_,
            factoryAddresses_,
            plasmaVaultBase_,
            priceOracleMiddleware_,
            burnRequestFeeFuse_,
            burnRequestFeeBalanceFuse_
        );
    }


    /// @notice Creates a new Fusion Vault by cloning existing contracts
    /// @param assetName_ The name of the asset
    /// @param assetSymbol_ The symbol of the asset
    /// @param underlyingToken_ The address of the underlying token
    /// @param redemptionDelayInSeconds_ The redemption delay in seconds
    /// @param owner_ The owner of the Fusion Vault
    /// @param daoFeePackageIndex_ Index of the DAO fee package to use
    /// @return The Fusion Vault instance
    /// @dev Recommended redemption delay is greater than 0 seconds to prevent immediate asset redemption after deposit, which helps protect against potential manipulation and ensures proper vault operation
    /// @dev This function clones existing contracts rather than deploying new ones, which is more gas efficient
    function clone(
        string memory assetName_,
        string memory assetSymbol_,
        address underlyingToken_,
        uint256 redemptionDelayInSeconds_,
        address owner_,
        uint256 daoFeePackageIndex_
    ) external returns (FusionFactoryLogicLib.FusionInstance memory) {
        return
            FusionFactoryLib.clone(
                assetName_,
                assetSymbol_,
                underlyingToken_,
                redemptionDelayInSeconds_,
                owner_,
                false,
                daoFeePackageIndex_
            );
    }

    /// @notice Creates a new Fusion Vault by cloning existing contracts, with admin role
    /// @param assetName_ The name of the asset
    /// @param assetSymbol_ The symbol of the asset
    /// @param underlyingToken_ The address of the underlying token
    /// @param redemptionDelayInSeconds_ The redemption delay in seconds
    /// @param owner_ The owner of the Fusion Vault
    /// @param daoFeePackageIndex_ Index of the DAO fee package to use
    /// @return The Fusion Vault instance
    /// @dev Recommended redemption delay is greater than 0 seconds to prevent immediate asset redemption after deposit, which helps protect against potential manipulation and ensures proper vault operation
    /// @dev This function clones existing contracts rather than deploying new ones, which is more gas efficient
    /// @dev Only callable by MAINTENANCE_MANAGER_ROLE
    function cloneSupervised(
        string memory assetName_,
        string memory assetSymbol_,
        address underlyingToken_,
        uint256 redemptionDelayInSeconds_,
        address owner_,
        uint256 daoFeePackageIndex_
    ) external onlyRole(MAINTENANCE_MANAGER_ROLE) returns (FusionFactoryLogicLib.FusionInstance memory) {
        return
            FusionFactoryLib.clone(
                assetName_,
                assetSymbol_,
                underlyingToken_,
                redemptionDelayInSeconds_,
                owner_,
                true,
                daoFeePackageIndex_
            );
    }

    /// @notice Creates a new Fusion Vault with explicit salt for cross-chain deterministic deployment
    /// @param assetName_ The name of the asset
    /// @param assetSymbol_ The symbol of the asset
    /// @param underlyingToken_ The address of the underlying token
    /// @param redemptionDelayInSeconds_ The redemption delay in seconds
    /// @param owner_ The owner of the Fusion Vault
    /// @param daoFeePackageIndex_ Index of the DAO fee package to use
    /// @param masterSalt_ User-provided master salt for cross-chain deterministic deployment
    /// @return The Fusion Vault instance with Phase 1 deployed and Phase 2 pre-computed
    /// @dev Only callable by MAINTENANCE_MANAGER_ROLE
    function cloneWithSalt(
        string memory assetName_,
        string memory assetSymbol_,
        address underlyingToken_,
        uint256 redemptionDelayInSeconds_,
        address owner_,
        uint256 daoFeePackageIndex_,
        bytes32 masterSalt_
    ) external onlyRole(MAINTENANCE_MANAGER_ROLE) returns (FusionFactoryLogicLib.FusionInstance memory) {
        FusionFactoryLogicLib.FusionInstance memory result = FusionFactoryLib.cloneWithSalt(
            assetName_,
            assetSymbol_,
            underlyingToken_,
            redemptionDelayInSeconds_,
            owner_,
            false,
            daoFeePackageIndex_,
            masterSalt_
        );

        emit VaultInstanceCreatedDeterministic(
            masterSalt_,
            result.plasmaVault,
            result.accessManager,
            result.priceManager,
            result.withdrawManager,
            result.feeManager,
            result.rewardsManager,
            result.contextManager
        );

        return result;
    }

    /// @notice Creates a new supervised Fusion Vault with explicit salt for cross-chain deterministic deployment
    /// @param assetName_ The name of the asset
    /// @param assetSymbol_ The symbol of the asset
    /// @param underlyingToken_ The address of the underlying token
    /// @param redemptionDelayInSeconds_ The redemption delay in seconds
    /// @param owner_ The owner of the Fusion Vault
    /// @param daoFeePackageIndex_ Index of the DAO fee package to use
    /// @param masterSalt_ User-provided master salt for cross-chain deterministic deployment
    /// @return The Fusion Vault instance with Phase 1 deployed and Phase 2 pre-computed
    /// @dev Only callable by MAINTENANCE_MANAGER_ROLE. Includes admin role assignment.
    function cloneSupervisedWithSalt(
        string memory assetName_,
        string memory assetSymbol_,
        address underlyingToken_,
        uint256 redemptionDelayInSeconds_,
        address owner_,
        uint256 daoFeePackageIndex_,
        bytes32 masterSalt_
    ) external onlyRole(MAINTENANCE_MANAGER_ROLE) returns (FusionFactoryLogicLib.FusionInstance memory) {
        FusionFactoryLogicLib.FusionInstance memory result = FusionFactoryLib.cloneWithSalt(
            assetName_,
            assetSymbol_,
            underlyingToken_,
            redemptionDelayInSeconds_,
            owner_,
            true,
            daoFeePackageIndex_,
            masterSalt_
        );

        emit VaultInstanceCreatedDeterministic(
            masterSalt_,
            result.plasmaVault,
            result.accessManager,
            result.priceManager,
            result.withdrawManager,
            result.feeManager,
            result.rewardsManager,
            result.contextManager
        );

        return result;
    }

    error UnauthorizedCaller();

    /// @notice Deploys a Phase 2 component (RewardsManager or ContextManager) at its pre-computed address
    /// @param plasmaVault_ The address of the plasma vault
    /// @param component_ The component to deploy
    /// @return deployedAddress The address of the deployed component
    /// @dev Callable by MAINTENANCE_MANAGER_ROLE on this factory OR by an account with ATOMIST_ROLE on the vault's AccessManager
    function deployComponent(
        address plasmaVault_,
        Component component_
    ) external returns (address deployedAddress) {
        if (!hasRole(MAINTENANCE_MANAGER_ROLE, msg.sender)) {
            address accessManager = IAccessManaged(plasmaVault_).authority();
            (bool isAtomist, ) = IporFusionAccessManager(accessManager).hasRole(Roles.ATOMIST_ROLE, msg.sender);
            if (!isAtomist) revert UnauthorizedCaller();
        }

        deployedAddress = FusionFactoryLib.deployComponent(plasmaVault_, component_);

        emit ComponentDeployed(plasmaVault_, component_, deployedAddress);
    }

    /// @notice Predicts all component addresses for a given master salt
    /// @param masterSalt_ The master salt to predict addresses for
    /// @return vault Predicted PlasmaVault address
    /// @return accessManager Predicted AccessManager address
    /// @return priceManager Predicted PriceManager address
    /// @return withdrawManager Predicted WithdrawManager address
    /// @return rewardsManager Predicted RewardsManager address
    /// @return contextManager Predicted ContextManager address
    function predictAddresses(
        bytes32 masterSalt_
    )
        external
        view
        returns (
            address vault,
            address accessManager,
            address priceManager,
            address withdrawManager,
            address rewardsManager,
            address contextManager
        )
    {
        return FusionFactoryLib.predictAddresses(masterSalt_);
    }

    /// @notice Predicts all component addresses for the next auto-deployment (via clone())
    /// @return vault Predicted PlasmaVault address
    /// @return accessManager Predicted AccessManager address
    /// @return priceManager Predicted PriceManager address
    /// @return withdrawManager Predicted WithdrawManager address
    /// @return rewardsManager Predicted RewardsManager address
    /// @return contextManager Predicted ContextManager address
    function predictNextAddresses()
        external
        view
        returns (
            address vault,
            address accessManager,
            address priceManager,
            address withdrawManager,
            address rewardsManager,
            address contextManager
        )
    {
        return FusionFactoryLib.predictNextAddresses();
    }

    /// @notice Returns the stored vault instance addresses for a given plasma vault
    /// @param plasmaVault_ Address of the plasma vault
    /// @return The vault instance addresses struct
    function getVaultInstanceAddresses(address plasmaVault_) external view returns (VaultInstanceAddresses memory) {
        return FusionFactoryStorageLib.getVaultInstanceAddresses(plasmaVault_);
    }

    function updatePlasmaVaultAdminArray(
        address[] memory newPlasmaVaultAdminArray_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i; i < newPlasmaVaultAdminArray_.length; i++) {
            if (newPlasmaVaultAdminArray_[i] == address(0)) revert FusionFactoryLib.InvalidAddress();
        }
        FusionFactoryStorageLib.setPlasmaVaultAdminArray(newPlasmaVaultAdminArray_);
        emit PlasmaVaultAdminArrayUpdated(newPlasmaVaultAdminArray_);
    }

    /// @notice Sets the DAO fee packages array (replaces entire array)
    /// @param packages_ Array of DAO fee packages to set
    /// @dev Each package must have valid fees (<=10000) and non-zero recipient
    function setDaoFeePackages(
        FusionFactoryStorageLib.FeePackage[] calldata packages_
    ) external onlyRole(DAO_FEE_MANAGER_ROLE) {
        if (packages_.length == 0) revert FusionFactoryLib.DaoFeePackagesArrayEmpty();

        uint256 length = packages_.length;
        for (uint256 i; i < length; ++i) {
            if (packages_[i].managementFee > 10000) {
                revert FusionFactoryLib.FeeExceedsMaximum(packages_[i].managementFee, 10000);
            }
            if (packages_[i].performanceFee > 10000) {
                revert FusionFactoryLib.FeeExceedsMaximum(packages_[i].performanceFee, 10000);
            }
            if (packages_[i].feeRecipient == address(0)) {
                revert FusionFactoryLib.FeeRecipientZeroAddress();
            }
        }

        // Convert calldata to memory for storage
        FusionFactoryStorageLib.FeePackage[] memory packagesMemory = new FusionFactoryStorageLib.FeePackage[](length);
        for (uint256 i; i < length; ++i) {
            packagesMemory[i] = packages_[i];
        }

        FusionFactoryStorageLib.setDaoFeePackages(packagesMemory);
        emit DaoFeePackagesUpdated(packagesMemory, msg.sender);
    }

    /// @notice Updates the factory addresses
    /// @param version_ Version of the Fusion Vault, version should be incremented when new features are added to the Fusion Vault
    /// @param newFactoryAddresses_ New factory addresses
    function updateFactoryAddresses(
        uint256 version_,
        FusionFactoryStorageLib.FactoryAddresses memory newFactoryAddresses_
    ) external onlyRole(MAINTENANCE_MANAGER_ROLE) {
        if (newFactoryAddresses_.accessManagerFactory == address(0)) revert FusionFactoryLib.InvalidAddress();
        if (newFactoryAddresses_.plasmaVaultFactory == address(0)) revert FusionFactoryLib.InvalidAddress();
        if (newFactoryAddresses_.feeManagerFactory == address(0)) revert FusionFactoryLib.InvalidAddress();
        if (newFactoryAddresses_.withdrawManagerFactory == address(0)) revert FusionFactoryLib.InvalidAddress();
        if (newFactoryAddresses_.rewardsManagerFactory == address(0)) revert FusionFactoryLib.InvalidAddress();
        if (newFactoryAddresses_.contextManagerFactory == address(0)) revert FusionFactoryLib.InvalidAddress();
        if (newFactoryAddresses_.priceManagerFactory == address(0)) revert FusionFactoryLib.InvalidAddress();

        FusionFactoryStorageLib.setFusionFactoryVersion(version_);
        FusionFactoryStorageLib.setPlasmaVaultFactoryAddress(newFactoryAddresses_.plasmaVaultFactory);
        FusionFactoryStorageLib.setAccessManagerFactoryAddress(newFactoryAddresses_.accessManagerFactory);
        FusionFactoryStorageLib.setFeeManagerFactoryAddress(newFactoryAddresses_.feeManagerFactory);
        FusionFactoryStorageLib.setWithdrawManagerFactoryAddress(newFactoryAddresses_.withdrawManagerFactory);
        FusionFactoryStorageLib.setRewardsManagerFactoryAddress(newFactoryAddresses_.rewardsManagerFactory);
        FusionFactoryStorageLib.setContextManagerFactoryAddress(newFactoryAddresses_.contextManagerFactory);
        FusionFactoryStorageLib.setPriceManagerFactoryAddress(newFactoryAddresses_.priceManagerFactory);

        emit FactoryAddressesUpdated({
            version: version_,
            accessManagerFactory: newFactoryAddresses_.accessManagerFactory,
            plasmaVaultFactory: newFactoryAddresses_.plasmaVaultFactory,
            feeManagerFactory: newFactoryAddresses_.feeManagerFactory,
            withdrawManagerFactory: newFactoryAddresses_.withdrawManagerFactory,
            rewardsManagerFactory: newFactoryAddresses_.rewardsManagerFactory,
            contextManagerFactory: newFactoryAddresses_.contextManagerFactory,
            priceManagerFactory: newFactoryAddresses_.priceManagerFactory
        });
    }

    /// @notice Updates the base contract addresses used for cloning new components
    /// @param version_ Version number to track base contract updates
    /// @param newPlasmaVaultCoreBase_ New base address for PlasmaVaultCore implementation
    /// @param newAccessManagerBase_ New base address for AccessManager implementation
    /// @param newPriceManagerBase_ New base address for PriceManager implementation
    /// @param newWithdrawManagerBase_ New base address for WithdrawManager implementation
    /// @param newRewardsManagerBase_ New base address for RewardsManager implementation
    /// @param newContextManagerBase_ New base address for ContextManager implementation
    /// @dev These base contracts serve as templates that are cloned when creating new vaults
    /// @custom:access Restricted to MAINTENANCE_MANAGER_ROLE
    function updateBaseAddresses(
        uint256 version_,
        address newPlasmaVaultCoreBase_,
        address newAccessManagerBase_,
        address newPriceManagerBase_,
        address newWithdrawManagerBase_,
        address newRewardsManagerBase_,
        address newContextManagerBase_
    ) external onlyRole(MAINTENANCE_MANAGER_ROLE) {
        if (newPlasmaVaultCoreBase_ == address(0)) revert FusionFactoryLib.InvalidAddress();
        if (newAccessManagerBase_ == address(0)) revert FusionFactoryLib.InvalidAddress();
        if (newPriceManagerBase_ == address(0)) revert FusionFactoryLib.InvalidAddress();
        if (newWithdrawManagerBase_ == address(0)) revert FusionFactoryLib.InvalidAddress();
        if (newRewardsManagerBase_ == address(0)) revert FusionFactoryLib.InvalidAddress();
        if (newContextManagerBase_ == address(0)) revert FusionFactoryLib.InvalidAddress();

        FusionFactoryStorageLib.setFusionFactoryVersion(version_);

        FusionFactoryStorageLib.setPlasmaVaultCoreBaseAddress(newPlasmaVaultCoreBase_);
        FusionFactoryStorageLib.setAccessManagerBaseAddress(newAccessManagerBase_);
        FusionFactoryStorageLib.setPriceManagerBaseAddress(newPriceManagerBase_);
        FusionFactoryStorageLib.setWithdrawManagerBaseAddress(newWithdrawManagerBase_);
        FusionFactoryStorageLib.setRewardsManagerBaseAddress(newRewardsManagerBase_);
        FusionFactoryStorageLib.setContextManagerBaseAddress(newContextManagerBase_);

        emit BaseAddressesUpdated(
            version_,
            newPlasmaVaultCoreBase_,
            newAccessManagerBase_,
            newPriceManagerBase_,
            newWithdrawManagerBase_,
            newRewardsManagerBase_,
            newContextManagerBase_
        );
    }

    function updatePlasmaVaultBase(address newPlasmaVaultBase_) external onlyRole(MAINTENANCE_MANAGER_ROLE) {
        if (newPlasmaVaultBase_ == address(0)) revert FusionFactoryLib.InvalidAddress();
        FusionFactoryStorageLib.setPlasmaVaultBaseAddress(newPlasmaVaultBase_);
        emit PlasmaVaultBaseUpdated(newPlasmaVaultBase_);
    }

    /// @notice Updates the default price oracle middleware address
    /// @param newPriceOracleMiddleware_ New price oracle middleware address
    function updatePriceOracleMiddleware(
        address newPriceOracleMiddleware_
    ) external onlyRole(MAINTENANCE_MANAGER_ROLE) {
        if (newPriceOracleMiddleware_ == address(0)) revert FusionFactoryLib.InvalidAddress();
        FusionFactoryStorageLib.setPriceOracleMiddlewareAddress(newPriceOracleMiddleware_);
        emit PriceOracleMiddlewareUpdated(newPriceOracleMiddleware_);
    }

    function updateBurnRequestFeeFuse(address newBurnRequestFeeFuse_) external onlyRole(MAINTENANCE_MANAGER_ROLE) {
        if (newBurnRequestFeeFuse_ == address(0)) revert FusionFactoryLib.InvalidAddress();
        FusionFactoryStorageLib.setBurnRequestFeeFuseAddress(newBurnRequestFeeFuse_);
        emit BurnRequestFeeFuseUpdated(newBurnRequestFeeFuse_);
    }

    function updateBurnRequestFeeBalanceFuse(
        address newBurnRequestFeeBalanceFuse_
    ) external onlyRole(MAINTENANCE_MANAGER_ROLE) {
        if (newBurnRequestFeeBalanceFuse_ == address(0)) revert FusionFactoryLib.InvalidAddress();
        FusionFactoryStorageLib.setBurnRequestFeeBalanceFuseAddress(newBurnRequestFeeBalanceFuse_);
        emit BurnRequestFeeBalanceFuseUpdated(newBurnRequestFeeBalanceFuse_);
    }

    function updateWithdrawWindowInSeconds(
        uint256 newWithdrawWindowInSeconds_
    ) external onlyRole(MAINTENANCE_MANAGER_ROLE) {
        if (newWithdrawWindowInSeconds_ == 0) revert FusionFactoryLib.InvalidWithdrawWindow();
        FusionFactoryStorageLib.setWithdrawWindowInSeconds(newWithdrawWindowInSeconds_);
        emit WithdrawWindowInSecondsUpdated(newWithdrawWindowInSeconds_);
    }

    function updateVestingPeriodInSeconds(
        uint256 newVestingPeriodInSeconds_
    ) external onlyRole(MAINTENANCE_MANAGER_ROLE) {
        FusionFactoryStorageLib.setVestingPeriodInSeconds(newVestingPeriodInSeconds_);
        emit VestingPeriodInSecondsUpdated(newVestingPeriodInSeconds_);
    }

    function getFusionFactoryVersion() external view returns (uint256) {
        return FusionFactoryStorageLib.getFusionFactoryVersion();
    }

    function getFusionFactoryIndex() external view returns (uint256) {
        return FusionFactoryStorageLib.getFusionFactoryIndex();
    }

    function getPlasmaVaultAdminArray() external view returns (address[] memory) {
        return FusionFactoryStorageLib.getPlasmaVaultAdminArray();
    }

    function getFactoryAddresses() external view returns (FusionFactoryStorageLib.FactoryAddresses memory) {
        return FusionFactoryStorageLib.getFactoryAddresses();
    }

    function getBaseAddresses() external view returns (FusionFactoryStorageLib.BaseAddresses memory) {
        return FusionFactoryStorageLib.getBaseAddresses();
    }

    function getPlasmaVaultBaseAddress() external view returns (address) {
        return FusionFactoryStorageLib.getPlasmaVaultBaseAddress();
    }

    function getPriceOracleMiddleware() external view returns (address) {
        return FusionFactoryStorageLib.getPriceOracleMiddleware();
    }

    function getBurnRequestFeeBalanceFuseAddress() external view returns (address) {
        return FusionFactoryStorageLib.getBurnRequestFeeBalanceFuseAddress();
    }

    function getBurnRequestFeeFuseAddress() external view returns (address) {
        return FusionFactoryStorageLib.getBurnRequestFeeFuseAddress();
    }

    function getWithdrawWindowInSeconds() external view returns (uint256) {
        return FusionFactoryStorageLib.getWithdrawWindowInSeconds();
    }

    function getVestingPeriodInSeconds() external view returns (uint256) {
        return FusionFactoryStorageLib.getVestingPeriodInSeconds();
    }

    /// @notice Returns all DAO fee packages
    /// @return Array of DAO fee packages
    function getDaoFeePackages() external view returns (FusionFactoryStorageLib.FeePackage[] memory) {
        return FusionFactoryStorageLib.getDaoFeePackages();
    }

    /// @notice Returns a specific DAO fee package by index
    /// @param index_ Index of the DAO fee package
    /// @return DAO fee package at the specified index
    function getDaoFeePackage(uint256 index_) external view returns (FusionFactoryStorageLib.FeePackage memory) {
        uint256 length = FusionFactoryStorageLib.getDaoFeePackagesLength();
        if (index_ >= length) {
            revert FusionFactoryLib.DaoFeePackageIndexOutOfBounds(index_, length);
        }
        return FusionFactoryStorageLib.getDaoFeePackage(index_);
    }

    /// @notice Returns the number of DAO fee packages
    /// @return Number of DAO fee packages
    function getDaoFeePackagesLength() external view returns (uint256) {
        return FusionFactoryStorageLib.getDaoFeePackagesLength();
    }

    /// @dev Required by the OZ UUPS module
    /// @param newImplementation Address of the new implementation
    // solhint-disable-next-line no-empty-blocks
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

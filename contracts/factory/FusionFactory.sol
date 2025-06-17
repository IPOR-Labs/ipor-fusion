// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {FusionFactoryStorageLib} from "./lib/FusionFactoryStorageLib.sol";

import {FusionFactoryLib} from "./lib/FusionFactoryLib.sol";

import {FusionFactoryAccessControl} from "./FusionFactoryAccessControl.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/// @title FusionFactory
/// @notice Factory contract for creating and managing Fusion Managers
/// @dev This contract is responsible for deploying and initializing various manager contracts
contract FusionFactory is UUPSUpgradeable, PausableUpgradeable, FusionFactoryAccessControl {
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
    event PlasmaVaultBaseUpdated(address newPlasmaVaultBase);
    event PriceOracleMiddlewareUpdated(address newPriceOracleMiddleware);
    event BurnRequestFeeFuseUpdated(address newBurnRequestFeeFuse);
    event BurnRequestFeeBalanceFuseUpdated(address newBurnRequestFeeBalanceFuse);
    event DaoFeeUpdated(address newDaoFeeRecipient, uint256 newDaoManagementFee, uint256 newDaoPerformanceFee);
    event RedemptionDelayInSecondsUpdated(uint256 newRedemptionDelayInSeconds);
    event WithdrawWindowInSecondsUpdated(uint256 newWithdrawWindowInSeconds);
    event VestingPeriodInSecondsUpdated(uint256 newVestingPeriodInSeconds);
    event PlasmaVaultAdminArrayUpdated(address[] newPlasmaVaultAdminArray);

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

    function create(
        string memory assetName_,
        string memory assetSymbol_,
        address underlyingToken_,
        address owner_
    ) external whenNotPaused returns (FusionFactoryLib.FusionInstance memory) {
        return FusionFactoryLib.create(assetName_, assetSymbol_, underlyingToken_, owner_, false);
    }

    function createPremium(
        string memory assetName_,
        string memory assetSymbol_,
        address underlyingToken_,
        address owner_
    ) external whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) returns (FusionFactoryLib.FusionInstance memory) {
        return FusionFactoryLib.create(assetName_, assetSymbol_, underlyingToken_, owner_, true);
    }

    function pause() external onlyRole(PAUSE_MANAGER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
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

    function updateDaoFee(
        address newDaoFeeRecipient_,
        uint256 newDaoManagementFee_,
        uint256 newDaoPerformanceFee_
    ) external onlyRole(DAO_FEE_MANAGER_ROLE) {
        if (newDaoFeeRecipient_ == address(0)) revert FusionFactoryLib.InvalidAddress();
        if (newDaoManagementFee_ > 10000) revert FusionFactoryLib.InvalidFeeValue(); // 100% max
        if (newDaoPerformanceFee_ > 10000) revert FusionFactoryLib.InvalidFeeValue(); // 100% max
        FusionFactoryStorageLib.setDaoFeeRecipientAddress(newDaoFeeRecipient_);
        FusionFactoryStorageLib.setDaoManagementFee(newDaoManagementFee_);
        FusionFactoryStorageLib.setDaoPerformanceFee(newDaoPerformanceFee_);
        emit DaoFeeUpdated(newDaoFeeRecipient_, newDaoManagementFee_, newDaoPerformanceFee_);
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

    function updateRedemptionDelayInSeconds(
        uint256 newRedemptionDelayInSeconds_
    ) external onlyRole(MAINTENANCE_MANAGER_ROLE) {
        if (newRedemptionDelayInSeconds_ == 0) revert FusionFactoryLib.InvalidRedemptionDelay();
        FusionFactoryStorageLib.setRedemptionDelayInSeconds(newRedemptionDelayInSeconds_);
        emit RedemptionDelayInSecondsUpdated(newRedemptionDelayInSeconds_);
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

    function getDaoFeeRecipientAddress() external view returns (address) {
        return FusionFactoryStorageLib.getDaoFeeRecipientAddress();
    }

    function getDaoManagementFee() external view returns (uint256) {
        return FusionFactoryStorageLib.getDaoManagementFee();
    }

    function getDaoPerformanceFee() external view returns (uint256) {
        return FusionFactoryStorageLib.getDaoPerformanceFee();
    }

    function getRedemptionDelayInSeconds() external view returns (uint256) {
        return FusionFactoryStorageLib.getRedemptionDelayInSeconds();
    }

    function getWithdrawWindowInSeconds() external view returns (uint256) {
        return FusionFactoryStorageLib.getWithdrawWindowInSeconds();
    }

    function getVestingPeriodInSeconds() external view returns (uint256) {
        return FusionFactoryStorageLib.getVestingPeriodInSeconds();
    }

    /// @dev Required by the OZ UUPS module
    /// @param newImplementation Address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

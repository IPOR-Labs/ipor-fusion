// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {RewardsManagerFactory} from "./RewardsManagerFactory.sol";
import {WithdrawManagerFactory} from "./WithdrawManagerFactory.sol";
import {ContextManagerFactory} from "./ContextManagerFactory.sol";
import {PriceManagerFactory} from "./PriceManagerFactory.sol";
import {PlasmaVaultFactory} from "./PlasmaVaultFactory.sol";
import {AccessManagerFactory} from "./AccessManagerFactory.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {FeeConfig} from "../managers/fee/FeeManagerFactory.sol";
import {DataForInitialization} from "../vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {PlasmaVaultInitData} from "../vaults/PlasmaVault.sol";
import {IporFusionAccessManagerInitializerLibV1} from "../vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {IporFusionAccessManager} from "../managers/access/IporFusionAccessManager.sol";
import {FeeManager} from "../managers/fee/FeeManager.sol";
import {FusionFactoryStorageLib} from "./lib/FusionFactoryStorageLib.sol";

import {IPlasmaVaultGovernance} from "../interfaces/IPlasmaVaultGovernance.sol";
import {PlasmaVaultStorageLib} from "../libraries/PlasmaVaultStorageLib.sol";
import {FeeAccount} from "../managers/fee/FeeAccount.sol";
import {IRewardsClaimManager} from "../interfaces/IRewardsClaimManager.sol";
import {WithdrawManager} from "../managers/withdraw/WithdrawManager.sol";
import {IporFusionMarkets} from "../libraries/IporFusionMarkets.sol";
import {FusionFactoryLib} from "./lib/FusionFactoryLib.sol";

/// @title FusionFactory
/// @notice Factory contract for creating and managing Fusion Managers
/// @dev This contract is responsible for deploying and initializing various manager contracts
contract FusionFactory is UUPSUpgradeable, Ownable2StepUpgradeable {
    event FactoryAddressesUpdated(FusionFactoryLib.FactoryAddresses newFactoryAddresses);
    event PlasmaVaultBaseUpdated(address newPlasmaVaultBase);
    event PriceOracleMiddlewareUpdated(address newPriceOracleMiddleware);
    event BurnRequestFeeFuseUpdated(address newBurnRequestFeeFuse);
    event BurnRequestFeeBalanceFuseUpdated(address newBurnRequestFeeBalanceFuse);
    event IporDaoFeeUpdated(
        address newIporDaoFeeRecipient,
        uint256 newIporDaoManagementFee,
        uint256 newIporDaoPerformanceFee
    );
    event RedemptionDelayInSecondsUpdated(uint256 newRedemptionDelayInSeconds);
    event WithdrawWindowInSecondsUpdated(uint256 newWithdrawWindowInSeconds);
    event VestingPeriodInSecondsUpdated(uint256 newVestingPeriodInSeconds);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        FusionFactoryLib.FactoryAddresses memory factoryAddresses_,
        address plasmaVaultBase_,
        address priceOracleMiddleware_,
        address burnRequestFeeFuse_,
        address burnRequestFeeBalanceFuse_
    ) external initializer {
        __Ownable_init(msg.sender);
        FusionFactoryLib.initialize(
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
    ) external returns (FusionFactoryLib.FusionInstance memory) {
        return FusionFactoryLib.create(assetName_, assetSymbol_, underlyingToken_, owner_);
    }

    function updateFactoryAddresses(FusionFactoryLib.FactoryAddresses memory newFactoryAddresses_) external onlyOwner {
        if (newFactoryAddresses_.accessManagerFactory == address(0)) revert FusionFactoryLib.InvalidAddress();
        if (newFactoryAddresses_.plasmaVaultFactory == address(0)) revert FusionFactoryLib.InvalidAddress();
        if (newFactoryAddresses_.feeManagerFactory == address(0)) revert FusionFactoryLib.InvalidAddress();
        if (newFactoryAddresses_.withdrawManagerFactory == address(0)) revert FusionFactoryLib.InvalidAddress();
        if (newFactoryAddresses_.rewardsManagerFactory == address(0)) revert FusionFactoryLib.InvalidAddress();
        if (newFactoryAddresses_.contextManagerFactory == address(0)) revert FusionFactoryLib.InvalidAddress();
        if (newFactoryAddresses_.priceManagerFactory == address(0)) revert FusionFactoryLib.InvalidAddress();

        FusionFactoryStorageLib.getPlasmaVaultFactoryAddressSlot().value = newFactoryAddresses_.plasmaVaultFactory;
        FusionFactoryStorageLib.getAccessManagerFactoryAddressSlot().value = newFactoryAddresses_.accessManagerFactory;
        FusionFactoryStorageLib.getFeeManagerFactoryAddressSlot().value = newFactoryAddresses_.feeManagerFactory;
        FusionFactoryStorageLib.getWithdrawManagerFactoryAddressSlot().value = newFactoryAddresses_
            .withdrawManagerFactory;
        FusionFactoryStorageLib.getRewardsManagerFactoryAddressSlot().value = newFactoryAddresses_
            .rewardsManagerFactory;
        FusionFactoryStorageLib.getContextManagerFactoryAddressSlot().value = newFactoryAddresses_
            .contextManagerFactory;
        FusionFactoryStorageLib.getPriceManagerFactoryAddressSlot().value = newFactoryAddresses_.priceManagerFactory;

        emit FactoryAddressesUpdated(newFactoryAddresses_);
    }

    function updatePlasmaVaultBase(address newPlasmaVaultBase_) external onlyOwner {
        if (newPlasmaVaultBase_ == address(0)) revert FusionFactoryLib.InvalidAddress();
        FusionFactoryStorageLib.getPlasmaVaultBaseAddressSlot().value = newPlasmaVaultBase_;
        emit PlasmaVaultBaseUpdated(newPlasmaVaultBase_);
    }

    /// @notice Updates the default price oracle middleware address
    /// @param newPriceOracleMiddleware_ New price oracle middleware address
    function updatePriceOracleMiddleware(address newPriceOracleMiddleware_) external onlyOwner {
        if (newPriceOracleMiddleware_ == address(0)) revert FusionFactoryLib.InvalidAddress();
        FusionFactoryStorageLib.getPriceOracleMiddlewareSlot().value = newPriceOracleMiddleware_;
        emit PriceOracleMiddlewareUpdated(newPriceOracleMiddleware_);
    }

    function updateBurnRequestFeeFuse(address newBurnRequestFeeFuse_) external onlyOwner {
        if (newBurnRequestFeeFuse_ == address(0)) revert FusionFactoryLib.InvalidAddress();
        FusionFactoryStorageLib.getBurnRequestFeeFuseAddressSlot().value = newBurnRequestFeeFuse_;
        emit BurnRequestFeeFuseUpdated(newBurnRequestFeeFuse_);
    }

    function updateBurnRequestFeeBalanceFuse(address newBurnRequestFeeBalanceFuse_) external onlyOwner {
        if (newBurnRequestFeeBalanceFuse_ == address(0)) revert FusionFactoryLib.InvalidAddress();
        FusionFactoryStorageLib.getBurnRequestFeeBalanceFuseAddressSlot().value = newBurnRequestFeeBalanceFuse_;
        emit BurnRequestFeeBalanceFuseUpdated(newBurnRequestFeeBalanceFuse_);
    }

    function updateIporDaoFee(
        address newIporDaoFeeRecipient_,
        uint256 newIporDaoManagementFee_,
        uint256 newIporDaoPerformanceFee_
    ) external onlyOwner {
        if (newIporDaoFeeRecipient_ == address(0)) revert FusionFactoryLib.InvalidAddress();
        if (newIporDaoManagementFee_ > 10000) revert FusionFactoryLib.InvalidFeeValue(); // 100% max
        if (newIporDaoPerformanceFee_ > 10000) revert FusionFactoryLib.InvalidFeeValue(); // 100% max
        FusionFactoryStorageLib.getIporDaoFeeRecipientAddressSlot().value = newIporDaoFeeRecipient_;
        FusionFactoryStorageLib.getIporDaoManagementFeeSlot().value = newIporDaoManagementFee_;
        FusionFactoryStorageLib.getIporDaoPerformanceFeeSlot().value = newIporDaoPerformanceFee_;
        emit IporDaoFeeUpdated(newIporDaoFeeRecipient_, newIporDaoManagementFee_, newIporDaoPerformanceFee_);
    }

    function updateRedemptionDelayInSeconds(uint256 newRedemptionDelayInSeconds_) external onlyOwner {
        if (newRedemptionDelayInSeconds_ == 0) revert FusionFactoryLib.InvalidRedemptionDelay();
        FusionFactoryStorageLib.getRedemptionDelayInSecondsSlot().value = newRedemptionDelayInSeconds_;
        emit RedemptionDelayInSecondsUpdated(newRedemptionDelayInSeconds_);
    }

    function updateWithdrawWindowInSeconds(uint256 newWithdrawWindowInSeconds_) external onlyOwner {
        if (newWithdrawWindowInSeconds_ == 0) revert FusionFactoryLib.InvalidWithdrawWindow();
        FusionFactoryStorageLib.getWithdrawWindowInSecondsSlot().value = newWithdrawWindowInSeconds_;
        emit WithdrawWindowInSecondsUpdated(newWithdrawWindowInSeconds_);
    }

    function updateVestingPeriodInSeconds(uint256 newVestingPeriodInSeconds_) external onlyOwner {
        if (newVestingPeriodInSeconds_ == 0) revert FusionFactoryLib.InvalidVestingPeriod();
        FusionFactoryStorageLib.getVestingPeriodInSecondsSlot().value = newVestingPeriodInSeconds_;
        emit VestingPeriodInSecondsUpdated(newVestingPeriodInSeconds_);
    }

    function getFactoryAddresses() external view returns (FusionFactoryLib.FactoryAddresses memory) {
        return FusionFactoryLib.getFactoryAddresses();
    }

    function getPlasmaVaultBaseAddress() external view returns (address) {
        return FusionFactoryLib.getPlasmaVaultBaseAddress();
    }

    function getPriceOracleMiddleware() external view returns (address) {
        return FusionFactoryLib.getPriceOracleMiddleware();
    }

    function getBurnRequestFeeBalanceFuseAddress() external view returns (address) {
        return FusionFactoryLib.getBurnRequestFeeBalanceFuseAddress();
    }

    function getBurnRequestFeeFuseAddress() external view returns (address) {
        return FusionFactoryLib.getBurnRequestFeeFuseAddress();
    }

    function getIporDaoFeeRecipientAddress() external view returns (address) {
        return FusionFactoryLib.getIporDaoFeeRecipientAddress();
    }

    function getIporDaoManagementFee() external view returns (uint256) {
        return FusionFactoryLib.getIporDaoManagementFee();
    }

    function getIporDaoPerformanceFee() external view returns (uint256) {
        return FusionFactoryLib.getIporDaoPerformanceFee();
    }

    function getRedemptionDelayInSeconds() external view returns (uint256) {
        return FusionFactoryLib.getRedemptionDelayInSeconds();
    }

    function getWithdrawWindowInSeconds() external view returns (uint256) {
        return FusionFactoryLib.getWithdrawWindowInSeconds();
    }

    function getVestingPeriodInSeconds() external view returns (uint256) {
        return FusionFactoryLib.getVestingPeriodInSeconds();
    }

    /// @dev Required by the OZ UUPS module
    /// @param newImplementation Address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}

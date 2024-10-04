// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IporFeeAccount} from "./IporFeeAccount.sol";
import {PlasmaVaultGovernance} from "../../vaults/PlasmaVaultGovernance.sol";
import {Errors} from "../../libraries/errors/Errors.sol";

/// @notice Struct containing initialization data for the fee manager
/// @param iporDaoManagementFee Management fee percentage for the DAO (in percentage with 2 decimals, example 10000 is 100%, 100 is 1%)
/// @param iporDaoPerformanceFee Performance fee percentage for the DAO (in percentage with 2 decimals, example 10000 is 100%, 100 is 1%)
/// @param atomistManagementFee Management fee percentage for the atomist (in percentage with 2 decimals, example 10000 is 100%, 100 is 1%)
/// @param atomistPerformanceFee Performance fee percentage for the atomist (in percentage with 2 decimals, example 10000 is 100%, 100 is 1%)
/// @param initialAuthority Address of the initial authority
/// @param plasmaVault Address of the plasma vault
/// @param feeRecipientAddress Address of the fee recipient
/// @param iporDaoFeeRecipientAddress Address of the DAO fee recipient
struct FeeManagerInitData {
    uint256 iporDaoManagementFee;
    uint256 iporDaoPerformanceFee;
    uint256 atomistManagementFee;
    uint256 atomistPerformanceFee;
    address initialAuthority;
    address plasmaVault;
    address feeRecipientAddress;
    address iporDaoFeeRecipientAddress;
}

/// @title IporFusionFeeManager
/// @notice Manages the fees for the IporFusion protocol, including management and performance fees.
/// @dev Inherits from AccessManaged for access control.
contract IporFusionFeeManager is AccessManaged {
    event HarvestManagementFee(address receiver, uint256 amount);
    event HarvestPerformanceFee(address receiver, uint256 amount);
    event PerformanceFeeUpdated(uint256 newPerformanceFee);
    event ManagementFeeUpdated(uint256 newManagementFee);

    error NotInitialized();
    error AlreadyInitialized();
    error InvalidFeeRecipientAddress();

    address public immutable PERFORMANCE_FEE_ACCOUNT;
    address public immutable MANAGEMENT_FEE_ACCOUNT;
    /// @notice IPOR_DAO_MANAGEMENT_FEE is in percentage with 2 decimals, example 10000 is 100%, 100 is 1%
    uint256 public immutable IPOR_DAO_MANAGEMENT_FEE;
    /// @notice IPOR_DAO_PERFORMANCE_FEE is in percentage with 2 decimals, example 10000 is 100%, 100 is 1%
    uint256 public immutable IPOR_DAO_PERFORMANCE_FEE;

    address public immutable PLASMA_VAULT;

    address public feeRecipientAddress;
    address public iporDaoFeeRecipientAddress;

    /// @notice plasmaVaultPerformanceFee is in percentage with 2 decimals, example 10000 is 100%, 100 is 1%
    uint256 public plasmaVaultPerformanceFee;
    /// @notice plasmaVaultManagementFee is in percentage with 2 decimals, example 10000 is 100%, 100 is 1%
    uint256 public plasmaVaultManagementFee;

    /// @notice The flag indicating whether the contract is initialized, if it is, the value is greater than 0
    uint256 public initialized;

    constructor(FeeManagerInitData memory initData_) AccessManaged(initData_.initialAuthority) {
        PERFORMANCE_FEE_ACCOUNT = address(new IporFeeAccount(address(this)));
        MANAGEMENT_FEE_ACCOUNT = address(new IporFeeAccount(address(this)));

        IPOR_DAO_MANAGEMENT_FEE = initData_.iporDaoManagementFee;
        IPOR_DAO_PERFORMANCE_FEE = initData_.iporDaoPerformanceFee;

        plasmaVaultPerformanceFee = initData_.atomistPerformanceFee + IPOR_DAO_PERFORMANCE_FEE;
        plasmaVaultManagementFee = initData_.atomistManagementFee + IPOR_DAO_MANAGEMENT_FEE;

        feeRecipientAddress = initData_.feeRecipientAddress;
        iporDaoFeeRecipientAddress = initData_.iporDaoFeeRecipientAddress;

        PLASMA_VAULT = initData_.plasmaVault;
    }

    function initialize() external {
        if (initialized != 0) {
            revert AlreadyInitialized();
        }

        initialized = 1;
        IporFeeAccount(PERFORMANCE_FEE_ACCOUNT).approveMaxForFeeManager(PLASMA_VAULT);
        IporFeeAccount(MANAGEMENT_FEE_ACCOUNT).approveMaxForFeeManager(PLASMA_VAULT);
    }

    /// @notice Harvests the management fee and transfers it to the respective recipient addresses.
    /// @dev This function can only be called if the contract is initialized.
    /// It checks if the fee recipient addresses are valid and then calculates the amount to be transferred to the DAO
    /// and the remaining amount to the fee recipient. The function emits events for each transfer.
    /// @custom:modifier onlyInitialized Ensures the contract is initialized before executing the function.
    function harvestManagementFee() public onlyInitialized {
        if (feeRecipientAddress == address(0) || iporDaoFeeRecipientAddress == address(0)) {
            revert InvalidFeeRecipientAddress();
        }

        uint256 balance = IERC4626(PLASMA_VAULT).balanceOf(MANAGEMENT_FEE_ACCOUNT);

        if (balance == 0) {
            return;
        }

        uint256 decimals = IERC4626(PLASMA_VAULT).decimals();
        uint256 numberOfDecimals = 10 ** (decimals);

        uint256 percentageToTransferToDao = (IPOR_DAO_MANAGEMENT_FEE * numberOfDecimals) / plasmaVaultManagementFee;

        uint256 transferAmountToDao = Math.mulDiv(balance, percentageToTransferToDao, numberOfDecimals);

        IERC4626(PLASMA_VAULT).transferFrom(MANAGEMENT_FEE_ACCOUNT, iporDaoFeeRecipientAddress, transferAmountToDao);
        emit HarvestManagementFee(iporDaoFeeRecipientAddress, transferAmountToDao);

        IERC4626(PLASMA_VAULT).transferFrom(MANAGEMENT_FEE_ACCOUNT, feeRecipientAddress, balance - transferAmountToDao);
        emit HarvestManagementFee(feeRecipientAddress, balance - transferAmountToDao);
    }

    /// @notice Harvests the performance fee and transfers it to the respective recipient addresses.
    /// @dev This function can only be called if the contract is initialized.
    /// It checks if the fee recipient addresses are valid and then calculates the amount to be transferred to the DAO
    /// and the remaining amount to the fee recipient. The function emits events for each transfer.
    /// @custom:modifier onlyInitialized Ensures the contract is initialized before executing the function.
    function harvestPerformanceFee() public onlyInitialized {
        if (feeRecipientAddress == address(0) || iporDaoFeeRecipientAddress == address(0)) {
            revert InvalidFeeRecipientAddress();
        }

        uint256 balance = IERC4626(PLASMA_VAULT).balanceOf(PERFORMANCE_FEE_ACCOUNT);

        if (balance == 0) {
            return;
        }

        uint256 decimals = IERC4626(PLASMA_VAULT).decimals();
        uint256 numberOfDecimals = 10 ** (decimals);

        uint256 percentToTransferToDao = (IPOR_DAO_PERFORMANCE_FEE * numberOfDecimals) / plasmaVaultPerformanceFee;

        uint256 transferAmountToDao = Math.mulDiv(balance, percentToTransferToDao, numberOfDecimals);

        IERC4626(PLASMA_VAULT).transferFrom(PERFORMANCE_FEE_ACCOUNT, iporDaoFeeRecipientAddress, transferAmountToDao);
        emit HarvestPerformanceFee(iporDaoFeeRecipientAddress, transferAmountToDao);

        IERC4626(PLASMA_VAULT).transferFrom(
            PERFORMANCE_FEE_ACCOUNT,
            feeRecipientAddress,
            balance - transferAmountToDao
        );
        emit HarvestPerformanceFee(feeRecipientAddress, balance - transferAmountToDao);
    }

    /**
     * @notice Updates the performance fee and reconfigures it in the PlasmaVaultGovernance contract.
     * @param performanceFee_ The new performance fee to be added to the DAO performance fee.
     */
    function updatePerformanceFee(uint256 performanceFee_) external restricted {
        harvestPerformanceFee();

        uint256 newPerformanceFee = performanceFee_ + IPOR_DAO_PERFORMANCE_FEE;

        PlasmaVaultGovernance(PLASMA_VAULT).configurePerformanceFee(PERFORMANCE_FEE_ACCOUNT, newPerformanceFee);
        plasmaVaultPerformanceFee = newPerformanceFee;

        emit PerformanceFeeUpdated(newPerformanceFee);
    }

    /// @notice Updates the management fee and reconfigures it in the PlasmaVaultGovernance contract.
    /// @param managementFee_ The new management fee to be added to the DAO management fee.
    function updateManagementFee(uint256 managementFee_) external restricted {
        harvestManagementFee();

        uint256 newManagementFee = managementFee_ + IPOR_DAO_MANAGEMENT_FEE;

        PlasmaVaultGovernance(PLASMA_VAULT).configureManagementFee(MANAGEMENT_FEE_ACCOUNT, newManagementFee);
        plasmaVaultManagementFee = newManagementFee;

        emit ManagementFeeUpdated(newManagementFee);
    }

    /**
     * @notice Sets the address of the fee recipient.
     * @dev This function can only be called by an authorized account (ATOMIST_ROLE).
     * @param feeRecipientAddress_ The address to set as the fee recipient.
     * @custom:error WrongAddress Thrown if the provided address is the zero address.
     */
    function setFeeRecipientAddress(address feeRecipientAddress_) external restricted {
        if (feeRecipientAddress_ == address(0)) {
            revert Errors.WrongAddress();
        }

        feeRecipientAddress = feeRecipientAddress_;
    }

    /**
     * @notice Sets the address of the DAO fee recipient.
     * @dev This function can only be called by an authorized account (TECH_IPOR_DAO_ROLE).
     * @param iporDaoFeeRecipientAddress_ The address to set as the DAO fee recipient.
     * @custom:error InvalidAddress Thrown if the provided address is the zero address.
     */
    function setIporDaoFeeRecipientAddress(address iporDaoFeeRecipientAddress_) external restricted {
        if (iporDaoFeeRecipientAddress_ == address(0)) {
            revert Errors.WrongAddress();
        }

        iporDaoFeeRecipientAddress = iporDaoFeeRecipientAddress_;
    }

    modifier onlyInitialized() {
        if (initialized == 0) {
            revert NotInitialized();
        }
        _;
    }
}

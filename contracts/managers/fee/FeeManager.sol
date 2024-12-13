// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;
import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {FeeAccount} from "./FeeAccount.sol";
import {PlasmaVaultGovernance} from "../../vaults/PlasmaVaultGovernance.sol";
import {RecipientFee} from "../../vaults/PlasmaVault.sol";

/// @notice Struct containing initialization data for the fee manager
/// @param initialAuthority Address of the initial authority
/// @param plasmaVault Address of the plasma vault
/// @param iporDaoManagementFee Management fee percentage for the DAO (in percentage with 2 decimals, example 10000 is 100%, 100 is 1%)
/// @param iporDaoPerformanceFee Performance fee percentage for the DAO (in percentage with 2 decimals, example 10000 is 100%, 100 is 1%)
/// @param iporDaoFeeRecipientAddress Address of the DAO fee recipient
/// @param recipientManagementFees Array of recipient management fees
/// @param recipientPerformanceFees Array of recipient performance fees
struct FeeManagerInitData {
    address initialAuthority;
    address plasmaVault;
    uint256 iporDaoManagementFee;
    uint256 iporDaoPerformanceFee;
    address iporDaoFeeRecipientAddress;
    RecipientFee[] recipientManagementFees;
    RecipientFee[] recipientPerformanceFees;
}

struct FeeRecipientData {
    mapping(address recipient => uint256 feeValue) recipientFees;
    address[] recipientAddresses;
}

/// @title FeeManager
/// @notice Manages the fees for the IporFusion protocol, including management and performance fees.
/// Total performance fee percentage is the sum of all recipients performance fees + DAO performance fee, represented in percentage with 2 decimals, example 10000 is 100%, 100 is 1%
/// Total management fee percentage is the sum of all recipients management fees + DAO management fee, represented in percentage with 2 decimals, example 10000 is 100%, 100 is 1%
/// @dev Inherits from AccessManaged for access control.
contract FeeManager is AccessManaged {
    event HarvestManagementFee(address receiver, uint256 amount);
    event HarvestPerformanceFee(address receiver, uint256 amount);
    event PerformanceFeeUpdated(uint256 newPerformanceFee);
    event ManagementFeeUpdated(uint256 newManagementFee);
    event FeeRecipientAdded(address recipient);
    event FeeRecipientRemoved(address recipient);
    event RecipientFeeUpdated(address recipient, uint256 managementFee, uint256 performanceFee);

    error NotInitialized();
    error AlreadyInitialized();
    error InvalidFeeRecipientAddress();
    error DuplicateFeeRecipient();
    error FeeRecipientNotFound();
    error EmptyFeeRecipients();
    error InvalidFeePercentage();

    /// @notice Address of the plasma vault contract
    address public immutable PLASMA_VAULT;

    /// @notice Account where performance fees are collected before distribution to recipients and DAO
    address public immutable PERFORMANCE_FEE_ACCOUNT;

    /// @notice Account where management fees are collected before distribution to recipients and DAO
    address public immutable MANAGEMENT_FEE_ACCOUNT;

    /// @notice Management fee percentage for IPOR DAO (10000 = 100%, 100 = 1%)
    uint256 public immutable IPOR_DAO_MANAGEMENT_FEE;

    /// @notice Performance fee percentage for IPOR DAO (10000 = 100%, 100 = 1%)
    uint256 public immutable IPOR_DAO_PERFORMANCE_FEE;

    /// @notice Initialization status (0 = uninitialized, 1 = initialized)
    uint256 public initialized;

    /// @notice Address that receives the IPOR DAO portion of fees based on IPOR_DAO_MANAGEMENT_FEE and IPOR_DAO_PERFORMANCE_FEE values
    address public iporDaoFeeRecipientAddress;

    FeeRecipientData private managementFeeRecipientData;

    FeeRecipientData private performanceFeeRecipientData;

    /// @notice Total performance fee percentage (sum of all recipients performance fees + DAO performance fees), represented in percentage with 2 decimals, example 10000 is 100%, 100 is 1%
    uint256 public plasmaVaultPerformanceFee;

    /// @notice Total management fee percentage (sum of all recipients management fees + DAO management  fees), represented in percentage with 2 decimals, example 10000 is 100%, 100 is 1%
    uint256 public plasmaVaultManagementFee;

    constructor(FeeManagerInitData memory initData_) AccessManaged(initData_.initialAuthority) {
        PLASMA_VAULT = initData_.plasmaVault;

        PERFORMANCE_FEE_ACCOUNT = address(new FeeAccount(address(this)));
        MANAGEMENT_FEE_ACCOUNT = address(new FeeAccount(address(this)));

        IPOR_DAO_MANAGEMENT_FEE = initData_.iporDaoManagementFee;
        IPOR_DAO_PERFORMANCE_FEE = initData_.iporDaoPerformanceFee;

        iporDaoFeeRecipientAddress = initData_.iporDaoFeeRecipientAddress;

        uint256 totalManagementFee = IPOR_DAO_MANAGEMENT_FEE;
        uint256 totalPerformanceFee = IPOR_DAO_PERFORMANCE_FEE;

        if (initData_.recipientManagementFees.length > 0) {
            address[] memory managementFeeRecipientAddresses = new address[](initData_.recipientManagementFees.length);

            for (uint256 i = 0; i < initData_.recipientManagementFees.length; i++) {
                managementFeeRecipientAddresses[i] = initData_.recipientManagementFees[i].recipient;
                totalManagementFee += initData_.recipientManagementFees[i].feeValue;
                managementFeeRecipientData.recipientFees[initData_.recipientManagementFees[i].recipient] = initData_
                    .recipientManagementFees[i]
                    .feeValue;
            }
            managementFeeRecipientData.recipientAddresses = managementFeeRecipientAddresses;
        }

        if (initData_.recipientPerformanceFees.length > 0) {
            address[] memory performanceFeeRecipientAddresses = new address[](
                initData_.recipientPerformanceFees.length
            );

            for (uint256 i = 0; i < initData_.recipientPerformanceFees.length; i++) {
                performanceFeeRecipientAddresses[i] = initData_.recipientPerformanceFees[i].recipient;
                totalPerformanceFee += initData_.recipientPerformanceFees[i].feeValue;
                performanceFeeRecipientData.recipientFees[initData_.recipientPerformanceFees[i].recipient] = initData_
                    .recipientPerformanceFees[i]
                    .feeValue;
            }
            performanceFeeRecipientData.recipientAddresses = performanceFeeRecipientAddresses;
        }

        /// @dev Plasma Vault fees are the sum of all recipients fees + DAO fee, respectively for performance and management fees.
        /// @dev Values stored in FeeManager have to be equal to the values stored in PlasmaVault
        plasmaVaultPerformanceFee = totalPerformanceFee;
        plasmaVaultManagementFee = totalManagementFee;
    }

    function initialize() external {
        if (initialized != 0) {
            revert AlreadyInitialized();
        }

        initialized = 1;
        FeeAccount(PERFORMANCE_FEE_ACCOUNT).approveMaxForFeeManager(PLASMA_VAULT);
        FeeAccount(MANAGEMENT_FEE_ACCOUNT).approveMaxForFeeManager(PLASMA_VAULT);
    }

    /// @notice Harvests all fees and transfers them to the respective recipient addresses and the IPOR DAO.
    function harvestAllFees() external onlyInitialized {
        harvestManagementFee();
        harvestPerformanceFee();
    }

    /// @notice Harvests the management fee and transfers it to the respective recipient addresses.
    /// @dev This function can only be called if the contract is initialized.
    /// It checks if the fee recipient addresses are valid and then calculates the amount to be transferred to the DAO
    /// and the remaining amount to the fee recipient. The function emits events for each transfer.
    /// @custom:modifier onlyInitialized Ensures the contract is initialized before executing the function.
    function harvestManagementFee() public onlyInitialized {
        if (iporDaoFeeRecipientAddress == address(0)) {
            revert InvalidFeeRecipientAddress();
        }

        if (plasmaVaultManagementFee == 0) {
            /// @dev If the management fee is 0, no fees are collected
            return;
        }

        uint256 managementFeeBalance = IERC4626(PLASMA_VAULT).balanceOf(MANAGEMENT_FEE_ACCOUNT);

        if (managementFeeBalance == 0) {
            /// @dev If the balance is 0, no fees are collected
            return;
        }

        uint256 decimals = IERC4626(PLASMA_VAULT).decimals();
        uint256 numberOfDecimals = 10 ** (decimals);

        uint256 percentageToTransferToDao = (IPOR_DAO_MANAGEMENT_FEE * numberOfDecimals) / plasmaVaultManagementFee;

        uint256 transferAmountToDao = Math.mulDiv(managementFeeBalance, percentageToTransferToDao, numberOfDecimals);

        IERC4626(PLASMA_VAULT).transferFrom(MANAGEMENT_FEE_ACCOUNT, iporDaoFeeRecipientAddress, transferAmountToDao);

        emit HarvestManagementFee(iporDaoFeeRecipientAddress, transferAmountToDao);

        if (managementFeeBalance <= transferAmountToDao) {
            return;
        }

        uint256 remainingBalance = managementFeeBalance - transferAmountToDao;

        if (remainingBalance == 0) {
            return;
        }

        address[] memory feeRecipientAddresses = managementFeeRecipientData.recipientAddresses;

        address recipient;
        uint256 recipientShare;
        uint256 recipientPercentage;

        for (uint256 i = 0; i < feeRecipientAddresses.length; i++) {
            recipient = feeRecipientAddresses[i];
            recipientPercentage =
                (managementFeeRecipientData.recipientFees[recipient] * numberOfDecimals) /
                plasmaVaultManagementFee;

            recipientShare = Math.mulDiv(managementFeeBalance, recipientPercentage, numberOfDecimals);

            if (recipientShare > 0) {
                if (remainingBalance < recipientShare) {
                    recipientShare = remainingBalance;
                }

                remainingBalance -= recipientShare;

                IERC4626(PLASMA_VAULT).transferFrom(MANAGEMENT_FEE_ACCOUNT, recipient, recipientShare);
                emit HarvestManagementFee(recipient, recipientShare);
            }
        }
    }

    /// @notice Harvests the performance fee and transfers it to the respective recipient addresses.
    /// @dev This function can only be called if the contract is initialized.
    /// It checks if the fee recipient addresses are valid and then calculates the amount to be transferred to the DAO
    /// and the remaining amount to the fee recipient. The function emits events for each transfer.
    /// @custom:modifier onlyInitialized Ensures the contract is initialized before executing the function.
    function harvestPerformanceFee() public onlyInitialized {
        if (iporDaoFeeRecipientAddress == address(0)) {
            revert InvalidFeeRecipientAddress();
        }

        if (plasmaVaultPerformanceFee == 0) {
            /// @dev If the performance fee is 0, no fees are collected
            return;
        }

        uint256 performanceFeeBalance = IERC4626(PLASMA_VAULT).balanceOf(PERFORMANCE_FEE_ACCOUNT);

        if (performanceFeeBalance == 0) {
            /// @dev If the balance is 0, no fees are collected
            return;
        }

        uint256 decimals = IERC4626(PLASMA_VAULT).decimals();
        uint256 numberOfDecimals = 10 ** (decimals);

        uint256 percentToTransferToDao = (IPOR_DAO_PERFORMANCE_FEE * numberOfDecimals) / plasmaVaultPerformanceFee;

        uint256 transferAmountToDao = Math.mulDiv(performanceFeeBalance, percentToTransferToDao, numberOfDecimals);

        if (transferAmountToDao > 0) {
            IERC4626(PLASMA_VAULT).transferFrom(
                PERFORMANCE_FEE_ACCOUNT,
                iporDaoFeeRecipientAddress,
                transferAmountToDao
            );
            emit HarvestPerformanceFee(iporDaoFeeRecipientAddress, transferAmountToDao);
        }

        if (performanceFeeBalance <= transferAmountToDao) {
            return;
        }

        uint256 remainingBalance = performanceFeeBalance - transferAmountToDao;

        if (remainingBalance == 0) {
            return;
        }

        address[] memory feeRecipientAddresses = performanceFeeRecipientData.recipientAddresses;

        address recipient;
        uint256 recipientShare;
        uint256 recipientPercentage;

        for (uint256 i = 0; i < feeRecipientAddresses.length && remainingBalance > 0; i++) {
            recipient = feeRecipientAddresses[i];
            recipientPercentage =
                (performanceFeeRecipientData.recipientFees[recipient] * numberOfDecimals) /
                plasmaVaultPerformanceFee;
            recipientShare = Math.mulDiv(performanceFeeBalance, recipientPercentage, numberOfDecimals);

            if (recipientShare > 0) {
                if (remainingBalance < recipientShare) {
                    recipientShare = remainingBalance;
                }

                remainingBalance -= recipientShare;

                IERC4626(PLASMA_VAULT).transferFrom(PERFORMANCE_FEE_ACCOUNT, recipient, recipientShare);
                emit HarvestPerformanceFee(recipient, recipientShare);
            }
        }
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

    // /**
    //  * @notice Adds a fee recipient.
    //  * @dev This function can only be called by an authorized account (ATOMIST_ROLE).
    //  * @param recipient The address to add as a fee recipient.
    //  * @custom:error WrongAddress Thrown if the provided address is the zero address.
    //  * @custom:error DuplicateFeeRecipient Thrown if the recipient is already added.
    //  */
    // function addFeeRecipient(address recipient, uint256 managementFee_, uint256 performanceFee_) external restricted {
    //     if (recipient == address(0)) {
    //         revert Errors.WrongAddress();
    //     }
    //     for (uint256 i = 0; i < feeRecipientAddresses.length; i++) {
    //         if (feeRecipientAddresses[i] == recipient) {
    //             revert DuplicateFeeRecipient();
    //         }
    //     }

    //     feeRecipientAddresses.push(recipient);
    //     recipientManagementFees[recipient] = managementFee_;
    //     recipientPerformanceFees[recipient] = performanceFee_;

    //     // Update total fees
    //     uint256 newManagementFee = plasmaVaultManagementFee + managementFee_;
    //     uint256 newPerformanceFee = plasmaVaultPerformanceFee + performanceFee_;

    //     // Configure new fees in plasma vault
    //     PlasmaVaultGovernance(PLASMA_VAULT).configureManagementFee(MANAGEMENT_FEE_ACCOUNT, newManagementFee);
    //     PlasmaVaultGovernance(PLASMA_VAULT).configurePerformanceFee(PERFORMANCE_FEE_ACCOUNT, newPerformanceFee);

    //     plasmaVaultManagementFee = newManagementFee;
    //     plasmaVaultPerformanceFee = newPerformanceFee;

    //     emit FeeRecipientAdded(recipient);
    //     emit RecipientFeeUpdated(recipient, managementFee_, performanceFee_);
    //     emit ManagementFeeUpdated(newManagementFee);
    //     emit PerformanceFeeUpdated(newPerformanceFee);
    // }

    // /**
    //  * @notice Removes a fee recipient.
    //  * @dev This function can only be called by an authorized account (ATOMIST_ROLE).
    //  * @param recipient The address to remove as a fee recipient.
    //  * @custom:error WrongAddress Thrown if the provided address is the zero address.
    //  * @custom:error FeeRecipientNotFound Thrown if the recipient is not found.
    //  * @custom:error EmptyFeeRecipients Thrown if there are no fee recipients left.
    //  */
    // function removeFeeRecipient(address recipient) external restricted {
    //     if (feeRecipientAddresses.length == 1) {
    //         revert EmptyFeeRecipients();
    //     }

    //     uint256 recipientIndex;
    //     bool found;

    //     for (uint256 i = 0; i < feeRecipientAddresses.length; i++) {
    //         if (feeRecipientAddresses[i] == recipient) {
    //             recipientIndex = i;
    //             found = true;
    //             break;
    //         }
    //     }

    //     if (!found) {
    //         revert FeeRecipientNotFound();
    //     }

    //     // Replace recipient with last element and remove last element
    //     feeRecipientAddresses[recipientIndex] = feeRecipientAddresses[feeRecipientAddresses.length - 1];
    //     feeRecipientAddresses.pop();

    //     // Clean up the fee mappings
    //     delete recipientManagementFees[recipient];
    //     delete recipientPerformanceFees[recipient];

    //     emit FeeRecipientRemoved(recipient);
    // }

    // /**
    //  * @notice Updates individual recipient fees.
    //  * @dev This function can only be called by an authorized account (ATOMIST_ROLE).
    //  * @param recipient The address of the recipient to update fees for.
    //  * @param managementFee_ The new management fee percentage for the recipient.
    //  * @param performanceFee_ The new performance fee percentage for the recipient.
    //  * @custom:error WrongAddress Thrown if the provided address is the zero address.
    //  * @custom:error FeeRecipientNotFound Thrown if the recipient is not found.
    //  */
    // // function updateRecipientFee(
    //     address recipient,
    //     uint256 managementFee_,
    //     uint256 performanceFee_
    // ) external restricted {
    //     if (recipient == address(0)) revert Errors.WrongAddress();

    //     bool isValidRecipient = false;
    //     for (uint256 i = 0; i < feeRecipientAddresses.length; i++) {
    //         if (feeRecipientAddresses[i] == recipient) {
    //             isValidRecipient = true;
    //             break;
    //         }
    //     }
    //     if (!isValidRecipient) revert FeeRecipientNotFound();

    //     // Harvest existing fees before updating
    //     harvestManagementFee();
    //     harvestPerformanceFee();

    //     recipientManagementFees[recipient] = managementFee_;
    //     recipientPerformanceFees[recipient] = performanceFee_;

    //     // Recalculate total fees
    //     uint256 totalManagementFee = IPOR_DAO_MANAGEMENT_FEE;
    //     uint256 totalPerformanceFee = IPOR_DAO_PERFORMANCE_FEE;

    //     for (uint256 i = 0; i < feeRecipientAddresses.length; i++) {
    //         totalManagementFee += recipientManagementFees[feeRecipientAddresses[i]];
    //         totalPerformanceFee += recipientPerformanceFees[feeRecipientAddresses[i]];
    //     }

    //     // Update the plasma vault with new total fees
    //     PlasmaVaultGovernance(PLASMA_VAULT).configureManagementFee(MANAGEMENT_FEE_ACCOUNT, totalManagementFee);
    //     PlasmaVaultGovernance(PLASMA_VAULT).configurePerformanceFee(PERFORMANCE_FEE_ACCOUNT, totalPerformanceFee);

    //     plasmaVaultManagementFee = totalManagementFee;
    //     plasmaVaultPerformanceFee = totalPerformanceFee;

    //     emit RecipientFeeUpdated(recipient, managementFee_, performanceFee_);
    //     emit ManagementFeeUpdated(totalManagementFee);
    //     emit PerformanceFeeUpdated(totalPerformanceFee);
    // }

    modifier onlyInitialized() {
        if (initialized == 0) {
            revert NotInitialized();
        }
        _;
    }

    /// @notice Gets the management fee for a specific recipient
    /// @param recipient The address of the recipient
    /// @return The management fee value
    function getManagementFee(address recipient) external view returns (uint256) {
        return managementFeeRecipientData.recipientFees[recipient];
    }

    /// @notice Gets all management fee recipient addresses
    /// @return Array of recipient addresses
    function getManagementFeeRecipients() external view returns (address[] memory) {
        return managementFeeRecipientData.recipientAddresses;
    }

    /// @notice Gets the performance fee for a specific recipient
    /// @param recipient The address of the recipient
    /// @return The performance fee value
    function getPerformanceFee(address recipient) external view returns (uint256) {
        return performanceFeeRecipientData.recipientFees[recipient];
    }

    /// @notice Gets all performance fee recipient addresses
    /// @return Array of recipient addresses
    function getPerformanceFeeRecipients() external view returns (address[] memory) {
        return performanceFeeRecipientData.recipientAddresses;
    }
}

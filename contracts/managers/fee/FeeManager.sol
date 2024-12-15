// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;
import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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

/// @notice Struct containing data for a fee recipient
/// @param recipientFees Mapping of recipient addresses to their respective fee values
/// @param recipientAddresses Array of recipient addresses
struct FeeRecipientData {
    mapping(address recipient => uint256 feeValue) recipientFees;
    address[] recipientAddresses;
}

/// @notice Enum representing the type of fee
enum FeeType {
    MANAGEMENT,
    PERFORMANCE
}

/// @title FeeManager
/// @notice Manages the fees for the IporFusion protocol, including management and performance fees.
/// Total performance fee percentage is the sum of all recipients performance fees + DAO performance fee, represented in percentage with 2 decimals, example 10000 is 100%, 100 is 1%
/// Total management fee percentage is the sum of all recipients management fees + DAO management fee, represented in percentage with 2 decimals, example 10000 is 100%, 100 is 1%
/// @dev Inherits from AccessManaged for access control.
contract FeeManager is AccessManaged {
    event HarvestManagementFee(address receiver, uint256 amount);
    event HarvestPerformanceFee(address receiver, uint256 amount);
    event PerformanceFeeUpdated(
        uint256 totalFee,
        address[] recipients,
        uint256[] fees
    );
    event ManagementFeeUpdated(
        uint256 totalFee,
        address[] recipients,
        uint256[] fees
    );

    error NotInitialized();
    error AlreadyInitialized();
    error InvalidFeeRecipientAddress();


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

    /// @notice Total performance fee percentage (sum of all recipients performance fees + DAO performance fees), represented in percentage with 2 decimals, example 10000 is 100%, 100 is 1%
    uint256 public plasmaVaultTotalPerformanceFee;

    /// @notice Total management fee percentage (sum of all recipients management fees + DAO management  fees), represented in percentage with 2 decimals, example 10000 is 100%, 100 is 1%
    uint256 public plasmaVaultTotalManagementFee;

    FeeRecipientData private _managementFeeRecipientData;

    FeeRecipientData private _performanceFeeRecipientData;


    modifier onlyInitialized() {
        if (initialized == 0) {
            revert NotInitialized();
        }
        _;
    }

    constructor(FeeManagerInitData memory initData_) AccessManaged(initData_.initialAuthority) {
        PLASMA_VAULT = initData_.plasmaVault;

        PERFORMANCE_FEE_ACCOUNT = address(new FeeAccount(address(this)));
        MANAGEMENT_FEE_ACCOUNT = address(new FeeAccount(address(this)));

        IPOR_DAO_MANAGEMENT_FEE = initData_.iporDaoManagementFee;
        IPOR_DAO_PERFORMANCE_FEE = initData_.iporDaoPerformanceFee;

        iporDaoFeeRecipientAddress = initData_.iporDaoFeeRecipientAddress;

        uint256 totalManagementFee = IPOR_DAO_MANAGEMENT_FEE;
        uint256 totalPerformanceFee = IPOR_DAO_PERFORMANCE_FEE;

        uint256 recipientManagementFeesLength = initData_.recipientManagementFees.length;
        uint256 recipientPerformanceFeesLength = initData_.recipientPerformanceFees.length;

        if (recipientManagementFeesLength > 0) {
            address[] memory managementFeeRecipientAddresses = new address[](recipientManagementFeesLength);

            for (uint256 i; i < recipientManagementFeesLength; i++) {
                managementFeeRecipientAddresses[i] = initData_.recipientManagementFees[i].recipient;
                totalManagementFee += initData_.recipientManagementFees[i].feeValue;
                _managementFeeRecipientData.recipientFees[initData_.recipientManagementFees[i].recipient] = initData_
                    .recipientManagementFees[i]
                    .feeValue;
            }
            _managementFeeRecipientData.recipientAddresses = managementFeeRecipientAddresses;
        }

        if (recipientPerformanceFeesLength > 0) {
            address[] memory performanceFeeRecipientAddresses = new address[](recipientPerformanceFeesLength);

            for (uint256 i; i < recipientPerformanceFeesLength; i++) {
                performanceFeeRecipientAddresses[i] = initData_.recipientPerformanceFees[i].recipient;
                totalPerformanceFee += initData_.recipientPerformanceFees[i].feeValue;
                _performanceFeeRecipientData.recipientFees[initData_.recipientPerformanceFees[i].recipient] = initData_
                    .recipientPerformanceFees[i]
                    .feeValue;
            }
            _performanceFeeRecipientData.recipientAddresses = performanceFeeRecipientAddresses;
        }

        /// @dev Plasma Vault fees are the sum of all recipients fees + DAO fee, respectively for performance and management fees.
        /// @dev Values stored in FeeManager have to be equal to the values stored in PlasmaVault
        plasmaVaultTotalPerformanceFee = totalPerformanceFee;
        plasmaVaultTotalManagementFee = totalManagementFee;
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

        uint256 totalManagementFee = plasmaVaultTotalManagementFee;

        if (totalManagementFee == 0) {
            /// @dev If the management fee is 0, no fees are collected
            return;
        }

        uint256 managementFeeBalance = IERC4626(PLASMA_VAULT).balanceOf(MANAGEMENT_FEE_ACCOUNT);

        if (managementFeeBalance == 0) {
            /// @dev If the balance is 0, no fees are collected
            return;
        }

        uint256 remainingBalance = _transferDaoFee(
            MANAGEMENT_FEE_ACCOUNT,
            managementFeeBalance,
            totalManagementFee,
            IPOR_DAO_MANAGEMENT_FEE,
            FeeType.MANAGEMENT
        );

        if (remainingBalance == 0) {
            return;
        }

        address[] memory feeRecipientAddresses = _managementFeeRecipientData.recipientAddresses;

        uint256 feeRecipientAddressesLength = feeRecipientAddresses.length;

        for (uint256 i; i < feeRecipientAddressesLength && remainingBalance > 0; i++) {
            remainingBalance = _transferRecipientFee(
                feeRecipientAddresses[i],
                remainingBalance,
                managementFeeBalance,
                _managementFeeRecipientData.recipientFees[feeRecipientAddresses[i]],
                totalManagementFee,
                MANAGEMENT_FEE_ACCOUNT,
                FeeType.MANAGEMENT
            );
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

        uint256 totalPerformanceFee = plasmaVaultTotalPerformanceFee;

        if (totalPerformanceFee == 0) {
            /// @dev If the performance fee is 0, no fees are collected
            return;
        }

        uint256 performanceFeeBalance = IERC4626(PLASMA_VAULT).balanceOf(PERFORMANCE_FEE_ACCOUNT);

        if (performanceFeeBalance == 0) {
            /// @dev If the balance is 0, no fees are collected
            return;
        }

        uint256 remainingBalance = _transferDaoFee(
            PERFORMANCE_FEE_ACCOUNT,
            performanceFeeBalance,
            totalPerformanceFee,
            IPOR_DAO_PERFORMANCE_FEE,
            FeeType.PERFORMANCE
        );

        if (remainingBalance == 0) {
            return;
        }

        address[] memory feeRecipientAddresses = _performanceFeeRecipientData.recipientAddresses;

        uint256 feeRecipientAddressesLength = feeRecipientAddresses.length;

        for (uint256 i; i < feeRecipientAddressesLength && remainingBalance > 0; i++) {
            remainingBalance = _transferRecipientFee(
                feeRecipientAddresses[i],
                remainingBalance,
                performanceFeeBalance,
                _performanceFeeRecipientData.recipientFees[feeRecipientAddresses[i]],
                totalPerformanceFee,
                PERFORMANCE_FEE_ACCOUNT,
                FeeType.PERFORMANCE
            );
        }
    }

    /// @notice Updates management fees for all recipients, not including the DAO fee recipient which is set in the constructor and cannot be updated
    /// @param recipientFees Array of recipient fees containing address and new fee value
    function updateManagementFee(RecipientFee[] calldata recipientFees) external restricted {
        harvestManagementFee();
        _updateFees(
            recipientFees,
            _managementFeeRecipientData,
            IPOR_DAO_MANAGEMENT_FEE,
            MANAGEMENT_FEE_ACCOUNT,
            FeeType.MANAGEMENT
        );
    }

    /// @notice Updates performance fees for all recipients, not including the DAO fee recipient which is set in the constructor and cannot be updated
    /// @param recipientFees Array of recipient fees containing address and new fee value
    function updatePerformanceFee(RecipientFee[] calldata recipientFees) external restricted {
        harvestPerformanceFee();
        _updateFees(
            recipientFees,
            _performanceFeeRecipientData,
            IPOR_DAO_PERFORMANCE_FEE,
            PERFORMANCE_FEE_ACCOUNT,
            FeeType.PERFORMANCE
        );
    }

    /**
     * @notice Sets the address of the DAO fee recipient.
     * @dev This function can only be called by an authorized account (TECH_IPOR_DAO_ROLE).
     * @param iporDaoFeeRecipientAddress_ The address to set as the DAO fee recipient.
     * @custom:error InvalidAddress Thrown if the provided address is the zero address.
     */
    function setIporDaoFeeRecipientAddress(address iporDaoFeeRecipientAddress_) external restricted {
        if (iporDaoFeeRecipientAddress_ == address(0)) {
            revert InvalidFeeRecipientAddress();
        }

        iporDaoFeeRecipientAddress = iporDaoFeeRecipientAddress_;
    }

    /// @notice Internal function to update fees for recipients
    /// @param recipientFees Array of recipient fees containing address and new fee value
    /// @param feeData Storage reference to the fee recipient data
    /// @param daoFee The DAO fee percentage to include in total
    /// @param feeAccount The fee account address
    /// @param feeType The type of fee (MANAGEMENT or PERFORMANCE)
    function _updateFees(
        RecipientFee[] calldata recipientFees,
        FeeRecipientData storage feeData,
        uint256 daoFee,
        address feeAccount,
        FeeType feeType
    ) internal {
        uint256 totalFee = daoFee;
    
        address[] memory oldRecipients = feeData.recipientAddresses;

        uint256 oldRecipientsLength = oldRecipients.length;

        for (uint256 i; i < oldRecipientsLength; i++) {
            delete feeData.recipientFees[oldRecipients[i]];
        }
        
        delete feeData.recipientAddresses;
        
        address[] memory newRecipients = new address[](recipientFees.length);
        uint256[] memory newFees = new uint256[](recipientFees.length);

        uint256 recipientFeesLength = recipientFees.length;

        for (uint256 i; i < recipientFeesLength; i++) {
            if (recipientFees[i].recipient == address(0)) {
                revert InvalidFeeRecipientAddress();
            }
            
            newRecipients[i] = recipientFees[i].recipient;
            newFees[i] = recipientFees[i].feeValue;
            
            feeData.recipientFees[recipientFees[i].recipient] = recipientFees[i].feeValue;
            totalFee += recipientFees[i].feeValue;
        }

        feeData.recipientAddresses = newRecipients;

        if (feeType == FeeType.MANAGEMENT) {
            PlasmaVaultGovernance(PLASMA_VAULT).configureManagementFee(feeAccount, totalFee);
            plasmaVaultTotalManagementFee = totalFee;
            emit ManagementFeeUpdated(totalFee, newRecipients, newFees);
        } else {
            PlasmaVaultGovernance(PLASMA_VAULT).configurePerformanceFee(feeAccount, totalFee);
            plasmaVaultTotalPerformanceFee = totalFee;
            emit PerformanceFeeUpdated(totalFee, newRecipients, newFees);
        }
    }
    
    /// @notice Gets all management fee recipients with their corresponding fee values
    /// @return Array of RecipientFee structs containing recipient addresses and their fee values
    function getManagementFeeRecipients() external view returns (RecipientFee[] memory) {
        address[] memory recipients = _managementFeeRecipientData.recipientAddresses;
        uint256 length = recipients.length;
        RecipientFee[] memory recipientFees = new RecipientFee[](length);
        
        for (uint256 i; i < length; i++) {
            recipientFees[i] = RecipientFee({
                recipient: recipients[i],
                feeValue: _managementFeeRecipientData.recipientFees[recipients[i]]
            });
        }
        
        return recipientFees;
    }

    /// @notice Gets all performance fee recipients with their corresponding fee values
    /// @return Array of RecipientFee structs containing recipient addresses and their fee values
    function getPerformanceFeeRecipients() external view returns (RecipientFee[] memory) {
        address[] memory recipients = _performanceFeeRecipientData.recipientAddresses;
        uint256 length = recipients.length;
        RecipientFee[] memory recipientFees = new RecipientFee[](length);
        
        for (uint256 i; i < length; i++) {
            recipientFees[i] = RecipientFee({
                recipient: recipients[i],
                feeValue: _performanceFeeRecipientData.recipientFees[recipients[i]]
            });
        }
        
        return recipientFees;
    }


    /// @notice Internal function to transfer fees to the DAO
    /// @param feeAccount The address of the fee account
    /// @param feeBalance The balance of the fee account
    /// @param totalFee The total fee percentage
    /// @param daoFee The DAO fee percentage
    /// @param feeType The type of fee (PERFORMANCE or MANAGEMENT)
    /// @return The remaining balance after transferring fees to the DAO
    function _transferDaoFee(
        address feeAccount,
        uint256 feeBalance,
        uint256 totalFee,
        uint256 daoFee,
        FeeType feeType
    ) internal returns (uint256) {
        uint256 decimals = IERC4626(PLASMA_VAULT).decimals();
        uint256 numberOfDecimals = 10 ** decimals;

        uint256 percentToTransferToDao = (daoFee * numberOfDecimals) / totalFee;
        uint256 transferAmountToDao = Math.mulDiv(feeBalance, percentToTransferToDao, numberOfDecimals);

        if (transferAmountToDao > 0) {
            IERC4626(PLASMA_VAULT).transferFrom(feeAccount, iporDaoFeeRecipientAddress, transferAmountToDao);
            _emitHarvestEvent(iporDaoFeeRecipientAddress, transferAmountToDao, feeType);
        }

        return feeBalance > transferAmountToDao ? feeBalance - transferAmountToDao : 0;
    }

    /// @notice Internal function to emit harvest events
    /// @param recipient The address of the fee recipient
    /// @param amount The amount of fee to be harvested
    /// @param feeType The type of fee (PERFORMANCE or MANAGEMENT)
    function _emitHarvestEvent(address recipient, uint256 amount, FeeType feeType) internal {
        if (feeType == FeeType.PERFORMANCE) {
            emit HarvestPerformanceFee(recipient, amount);
        } else {
            emit HarvestManagementFee(recipient, amount);
        }
    }

    /// @notice Internal function to handle fee transfer to a recipient
    /// @param recipient The address of the fee recipient
    /// @param remainingBalance Current remaining balance to distribute
    /// @param totalFeeBalance Total fee balance being distributed
    /// @param recipientFeeValue The fee value for this specific recipient
    /// @param totalFeePercentage Total fee percentage (management or performance)
    /// @param feeAccount The fee account to transfer from
    /// @param feeType The type of fee ("MANAGEMENT" or "PERFORMANCE")
    /// @return The new remaining balance after transfer
    function _transferRecipientFee(
        address recipient,
        uint256 remainingBalance,
        uint256 totalFeeBalance,
        uint256 recipientFeeValue,
        uint256 totalFeePercentage,
        address feeAccount,
        FeeType feeType
    ) internal returns (uint256) {
        uint256 decimals = IERC4626(PLASMA_VAULT).decimals();
        uint256 numberOfDecimals = 10 ** decimals;
        
        uint256 recipientPercentage = (recipientFeeValue * numberOfDecimals) / totalFeePercentage;
        uint256 recipientShare = Math.mulDiv(totalFeeBalance, recipientPercentage, numberOfDecimals);

        if (recipientShare > 0) {
            if (remainingBalance < recipientShare) {
                recipientShare = remainingBalance;
            }

            remainingBalance -= recipientShare;

            IERC4626(PLASMA_VAULT).transferFrom(feeAccount, recipient, recipientShare);
            _emitHarvestEvent(recipient, recipientShare, feeType);
        }

        return remainingBalance;
    }
}

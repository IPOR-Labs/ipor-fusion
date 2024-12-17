// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {AccessManagedUpgradeable} from "../access/AccessManagedUpgradeable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FeeAccount} from "./FeeAccount.sol";
import {PlasmaVaultGovernance} from "../../vaults/PlasmaVaultGovernance.sol";
import {RecipientFee} from "./FeeManagerFactory.sol";
import {FeeManagerStorageLib, FeeRecipientDataStorage} from "./FeeManagerStorageLib.sol";
import {ContextClient} from "../context/ContextClient.sol";

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

/// @notice Struct containing data for a fee recipients
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
contract FeeManager is AccessManagedUpgradeable, ContextClient {
    event HarvestManagementFee(address receiver, uint256 amount);
    event HarvestPerformanceFee(address receiver, uint256 amount);
    event PerformanceFeeUpdated(uint256 totalFee, address[] recipients, uint256[] fees);
    event ManagementFeeUpdated(uint256 totalFee, address[] recipients, uint256[] fees);

    /// @notice Thrown when trying to call a function before initialization
    error NotInitialized();

    /// @notice Thrown when trying to initialize an already initialized contract
    error AlreadyInitialized();

    /// @notice Thrown when trying to set an invalid (zero) address as a fee recipient
    error InvalidFeeRecipientAddress();

    /// @notice Thrown when trying to set an invalid authority
    error InvalidAuthority();

    uint64 private constant INITIALIZED_VERSION = 10;

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

    modifier onlyInitialized() {
        if (_getInitializedVersion() != INITIALIZED_VERSION) {
            revert NotInitialized();
        }
        _;
    }

    constructor(FeeManagerInitData memory initData_) initializer {
        if (initData_.initialAuthority == address(0)) revert InvalidAuthority();

        super.__AccessManaged_init_unchained(initData_.initialAuthority);
        PLASMA_VAULT = initData_.plasmaVault;

        PERFORMANCE_FEE_ACCOUNT = address(new FeeAccount(address(this)));
        MANAGEMENT_FEE_ACCOUNT = address(new FeeAccount(address(this)));

        IPOR_DAO_MANAGEMENT_FEE = initData_.iporDaoManagementFee;
        IPOR_DAO_PERFORMANCE_FEE = initData_.iporDaoPerformanceFee;

        FeeManagerStorageLib.setIporDaoFeeRecipientAddress(initData_.iporDaoFeeRecipientAddress);

        uint256 totalManagementFee = IPOR_DAO_MANAGEMENT_FEE;
        uint256 totalPerformanceFee = IPOR_DAO_PERFORMANCE_FEE;

        uint256 recipientManagementFeesLength = initData_.recipientManagementFees.length;
        uint256 recipientPerformanceFeesLength = initData_.recipientPerformanceFees.length;

        if (recipientManagementFeesLength > 0) {
            address[] memory managementFeeRecipientAddresses = new address[](recipientManagementFeesLength);

            for (uint256 i; i < recipientManagementFeesLength; i++) {
                managementFeeRecipientAddresses[i] = initData_.recipientManagementFees[i].recipient;
                totalManagementFee += initData_.recipientManagementFees[i].feeValue;
                FeeManagerStorageLib.setManagementFeeRecipientFee(
                    initData_.recipientManagementFees[i].recipient,
                    initData_.recipientManagementFees[i].feeValue
                );
            }
            FeeManagerStorageLib.setManagementFeeRecipientAddresses(managementFeeRecipientAddresses);
        }

        if (recipientPerformanceFeesLength > 0) {
            address[] memory performanceFeeRecipientAddresses = new address[](recipientPerformanceFeesLength);

            for (uint256 i; i < recipientPerformanceFeesLength; i++) {
                performanceFeeRecipientAddresses[i] = initData_.recipientPerformanceFees[i].recipient;
                totalPerformanceFee += initData_.recipientPerformanceFees[i].feeValue;
                FeeManagerStorageLib.setPerformanceFeeRecipientFee(
                    initData_.recipientPerformanceFees[i].recipient,
                    initData_.recipientPerformanceFees[i].feeValue
                );
            }
            FeeManagerStorageLib.setPerformanceFeeRecipientAddresses(performanceFeeRecipientAddresses);
        }

        /// @dev Plasma Vault fees are the sum of all recipients fees + DAO fee, respectively for performance and management fees.
        /// @dev Values stored in FeeManager have to be equal to the values stored in PlasmaVault
        FeeManagerStorageLib.setPlasmaVaultTotalPerformanceFee(totalPerformanceFee);
        FeeManagerStorageLib.setPlasmaVaultTotalManagementFee(totalManagementFee);
    }

    /// @notice Initializes the FeeManager contract by setting up fee account approvals
    /// @dev Can only be called once due to reinitializer modifier
    /// @dev Sets maximum approval for both performance and management fee accounts to interact with plasma vault
    /// @dev This is required for the fee accounts to transfer tokens to recipients during fee distribution
    /// @custom:access Can only be called once during initialization
    /// @custom:error AlreadyInitialized if called after initialization
    function initialize() external reinitializer(INITIALIZED_VERSION) {
        FeeAccount(PERFORMANCE_FEE_ACCOUNT).approveMaxForFeeManager(PLASMA_VAULT);
        FeeAccount(MANAGEMENT_FEE_ACCOUNT).approveMaxForFeeManager(PLASMA_VAULT);
    }

    /// @notice Harvests both management and performance fees
    /// @dev Can be called by any address once initialized
    /// @dev This is a convenience function that calls harvestManagementFee() and harvestPerformanceFee()
    /// @custom:access Public after initialization
    function harvestAllFees() external onlyInitialized {
        harvestManagementFee();
        harvestPerformanceFee();
    }

    /// @notice Harvests the management fee and distributes it to recipients
    /// @dev Can be called by any address once initialized
    /// @dev Distributes fees proportionally based on configured fee percentages
    /// @dev First transfers the DAO portion, then distributes remaining to other recipients
    /// @custom:access Public after initialization
    function harvestManagementFee() public onlyInitialized {
        if (FeeManagerStorageLib.getIporDaoFeeRecipientAddress() == address(0)) {
            revert InvalidFeeRecipientAddress();
        }

        uint256 totalManagementFee = FeeManagerStorageLib.getPlasmaVaultTotalManagementFee();

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

        address[] memory feeRecipientAddresses = FeeManagerStorageLib.getManagementFeeRecipientAddresses();

        uint256 feeRecipientAddressesLength = feeRecipientAddresses.length;

        for (uint256 i; i < feeRecipientAddressesLength && remainingBalance > 0; i++) {
            remainingBalance = _transferRecipientFee(
                feeRecipientAddresses[i],
                remainingBalance,
                managementFeeBalance,
                FeeManagerStorageLib.getManagementFeeRecipientFee(feeRecipientAddresses[i]),
                totalManagementFee,
                MANAGEMENT_FEE_ACCOUNT,
                FeeType.MANAGEMENT
            );
        }
    }

    /// @notice Harvests the performance fee and distributes it to recipients
    /// @dev Can be called by any address once initialized
    /// @dev Distributes fees proportionally based on configured fee percentages
    /// @dev First transfers the DAO portion, then distributes remaining to other recipients
    /// @custom:access Public after initialization
    function harvestPerformanceFee() public onlyInitialized {
        if (FeeManagerStorageLib.getIporDaoFeeRecipientAddress() == address(0)) {
            revert InvalidFeeRecipientAddress();
        }

        uint256 totalPerformanceFee = FeeManagerStorageLib.getPlasmaVaultTotalPerformanceFee();

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

        address[] memory feeRecipientAddresses = FeeManagerStorageLib.getPerformanceFeeRecipientAddresses();

        uint256 feeRecipientAddressesLength = feeRecipientAddresses.length;

        for (uint256 i; i < feeRecipientAddressesLength && remainingBalance > 0; i++) {
            remainingBalance = _transferRecipientFee(
                feeRecipientAddresses[i],
                remainingBalance,
                performanceFeeBalance,
                FeeManagerStorageLib.getPerformanceFeeRecipientFee(feeRecipientAddresses[i]),
                totalPerformanceFee,
                PERFORMANCE_FEE_ACCOUNT,
                FeeType.PERFORMANCE
            );
        }
    }

    /// @notice Updates management fees for all recipients
    /// @dev Only callable by ATOMIST_ROLE (role id: 100)
    /// @dev Harvests existing management fees before updating
    /// @dev Total management fee will be the sum of all recipient fees + DAO fee
    /// @param recipientFees Array of recipient fees containing address and new fee value
    /// @custom:access Restricted to ATOMIST_ROLE
    function updateManagementFee(RecipientFee[] calldata recipientFees) external restricted {
        harvestManagementFee();
        _updateFees(
            recipientFees,
            FeeManagerStorageLib._managementFeeRecipientDataStorage(),
            IPOR_DAO_MANAGEMENT_FEE,
            MANAGEMENT_FEE_ACCOUNT,
            FeeType.MANAGEMENT
        );
    }

    /// @notice Updates performance fees for all recipients
    /// @dev Only callable by ATOMIST_ROLE (role id: 100)
    /// @dev Harvests existing performance fees before updating
    /// @dev Total performance fee will be the sum of all recipient fees + DAO fee
    /// @param recipientFees Array of recipient fees containing address and new fee value
    /// @custom:access Restricted to ATOMIST_ROLE
    function updatePerformanceFee(RecipientFee[] calldata recipientFees) external restricted {
        harvestPerformanceFee();
        _updateFees(
            recipientFees,
            FeeManagerStorageLib._performanceFeeRecipientDataStorage(),
            IPOR_DAO_PERFORMANCE_FEE,
            PERFORMANCE_FEE_ACCOUNT,
            FeeType.PERFORMANCE
        );
    }

    /// @notice Sets the IPOR DAO fee recipient address
    /// @dev Only callable by IPOR_DAO_ROLE (role id: 4)
    /// @dev The DAO fee recipient receives both management and performance fees allocated to the DAO
    /// @param iporDaoFeeRecipientAddress_ The address to set as the DAO fee recipient
    /// @custom:access Restricted to IPOR_DAO_ROLE
    function setIporDaoFeeRecipientAddress(address iporDaoFeeRecipientAddress_) external restricted {
        if (iporDaoFeeRecipientAddress_ == address(0)) {
            revert InvalidFeeRecipientAddress();
        }
        FeeManagerStorageLib.setIporDaoFeeRecipientAddress(iporDaoFeeRecipientAddress_);
    }

    /// @notice Internal function to completely replace existing fee recipients with new ones
    /// @dev This function will remove all existing recipients and their fees before setting up the new ones
    /// @param recipientFees Array of recipient fees containing address and new fee value
    /// @param feeData Storage reference to the fee recipient data
    /// @param daoFee The DAO fee percentage to include in total
    /// @param feeAccount The fee account address
    /// @param feeType The type of fee (MANAGEMENT or PERFORMANCE)
    function _updateFees(
        RecipientFee[] calldata recipientFees,
        FeeRecipientDataStorage storage feeData,
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
            FeeManagerStorageLib.setPlasmaVaultTotalManagementFee(totalFee);
            emit ManagementFeeUpdated(totalFee, newRecipients, newFees);
        } else {
            PlasmaVaultGovernance(PLASMA_VAULT).configurePerformanceFee(feeAccount, totalFee);
            FeeManagerStorageLib.setPlasmaVaultTotalPerformanceFee(totalFee);
            emit PerformanceFeeUpdated(totalFee, newRecipients, newFees);
        }
    }

    /// @notice Gets all management fee recipients with their fee values
    /// @dev View function accessible by anyone
    /// @return Array of RecipientFee structs containing recipient addresses and their fee values
    /// @custom:access Public view
    function getManagementFeeRecipients() external view returns (RecipientFee[] memory) {
        address[] memory recipients = FeeManagerStorageLib.getManagementFeeRecipientAddresses();
        uint256 length = recipients.length;

        RecipientFee[] memory recipientFees = new RecipientFee[](length);

        for (uint256 i; i < length; i++) {
            recipientFees[i] = RecipientFee({
                recipient: recipients[i],
                feeValue: FeeManagerStorageLib.getManagementFeeRecipientFee(recipients[i])
            });
        }

        return recipientFees;
    }

    /// @notice Gets all performance fee recipients with their fee values
    /// @dev View function accessible by anyone
    /// @return Array of RecipientFee structs containing recipient addresses and their fee values
    /// @custom:access Public view
    function getPerformanceFeeRecipients() external view returns (RecipientFee[] memory) {
        address[] memory recipients = FeeManagerStorageLib.getPerformanceFeeRecipientAddresses();
        uint256 length = recipients.length;
        RecipientFee[] memory recipientFees = new RecipientFee[](length);

        for (uint256 i; i < length; i++) {
            recipientFees[i] = RecipientFee({
                recipient: recipients[i],
                feeValue: FeeManagerStorageLib.getPerformanceFeeRecipientFee(recipients[i])
            });
        }

        return recipientFees;
    }

    /// @notice Gets the total management fee percentage
    /// @dev View function accessible by anyone
    /// @return Total management fee percentage with 2 decimals (10000 = 100%, 100 = 1%)
    /// @custom:access Public view
    function getTotalManagementFee() external view returns (uint256) {
        return FeeManagerStorageLib.getPlasmaVaultTotalManagementFee();
    }

    /// @notice Gets the total performance fee percentage
    /// @dev View function accessible by anyone
    /// @return Total performance fee percentage with 2 decimals (10000 = 100%, 100 = 1%)
    /// @custom:access Public view
    function getTotalPerformanceFee() external view returns (uint256) {
        return FeeManagerStorageLib.getPlasmaVaultTotalPerformanceFee();
    }

    /// @notice Gets the IPOR DAO fee recipient address
    /// @dev View function accessible by anyone
    /// @return The current DAO fee recipient address
    /// @custom:access Public view
    function getIporDaoFeeRecipientAddress() external view returns (address) {
        return FeeManagerStorageLib.getIporDaoFeeRecipientAddress();
    }

    /// @notice Internal function to transfer fees to the DAO
    /// @param feeAccount_ The address of the fee account
    /// @param feeBalance_ The balance of the fee account
    /// @param totalFee_ The total fee percentage
    /// @param daoFee_ The DAO fee percentage
    /// @param feeType_ The type of fee (PERFORMANCE or MANAGEMENT)
    /// @return The remaining balance after transferring fees to the DAO
    function _transferDaoFee(
        address feeAccount_,
        uint256 feeBalance_,
        uint256 totalFee_,
        uint256 daoFee_,
        FeeType feeType_
    ) internal returns (uint256) {
        uint256 decimals = IERC4626(PLASMA_VAULT).decimals();
        uint256 numberOfDecimals = 10 ** decimals;

        uint256 percentToTransferToDao_ = (daoFee_ * numberOfDecimals) / totalFee_;
        uint256 transferAmountToDao_ = Math.mulDiv(feeBalance_, percentToTransferToDao_, numberOfDecimals);

        if (transferAmountToDao_ > 0) {
            IERC4626(PLASMA_VAULT).transferFrom(
                feeAccount_,
                FeeManagerStorageLib.getIporDaoFeeRecipientAddress(),
                transferAmountToDao_
            );
            _emitHarvestEvent(FeeManagerStorageLib.getIporDaoFeeRecipientAddress(), transferAmountToDao_, feeType_);
        }

        return feeBalance_ > transferAmountToDao_ ? feeBalance_ - transferAmountToDao_ : 0;
    }

    /// @notice Internal function to emit harvest events
    /// @param recipient_ The address of the fee recipient
    /// @param amount_ The amount of fee to be harvested
    /// @param feeType_ The type of fee (PERFORMANCE or MANAGEMENT)
    function _emitHarvestEvent(address recipient_, uint256 amount_, FeeType feeType_) internal {
        if (feeType_ == FeeType.PERFORMANCE) {
            emit HarvestPerformanceFee(recipient_, amount_);
        } else {
            emit HarvestManagementFee(recipient_, amount_);
        }
    }

    /// @notice Internal function to handle fee transfer to a recipient
    /// @param recipient_ The address of the fee recipient
    /// @param remainingBalance_ Current remaining balance to distribute
    /// @param totalFeeBalance_ Total fee balance being distributed
    /// @param recipientFeeValue_ The fee value for this specific recipient
    /// @param totalFeePercentage_ Total fee percentage (management or performance)
    /// @param feeAccount_ The fee account to transfer from
    /// @param feeType_ The type of fee ("MANAGEMENT" or "PERFORMANCE")
    /// @return The new remaining balance after transfer
    function _transferRecipientFee(
        address recipient_,
        uint256 remainingBalance_,
        uint256 totalFeeBalance_,
        uint256 recipientFeeValue_,
        uint256 totalFeePercentage_,
        address feeAccount_,
        FeeType feeType_
    ) internal returns (uint256) {
        uint256 decimals = IERC4626(PLASMA_VAULT).decimals();
        uint256 numberOfDecimals = 10 ** decimals;

        uint256 recipientPercentage = (recipientFeeValue_ * numberOfDecimals) / totalFeePercentage_;
        uint256 recipientShare = Math.mulDiv(totalFeeBalance_, recipientPercentage, numberOfDecimals);

        if (recipientShare > 0) {
            if (remainingBalance_ < recipientShare) {
                recipientShare = remainingBalance_;
            }

            remainingBalance_ -= recipientShare;

            IERC4626(PLASMA_VAULT).transferFrom(feeAccount_, recipient_, recipientShare);
            _emitHarvestEvent(recipient_, recipientShare, feeType_);
        }

        return remainingBalance_;
    }

    /// @notice Internal function to get the message sender from context
    /// @return The address of the message sender
    function _msgSender() internal view override returns (address) {
        return _getSenderFromContext();
    }
}

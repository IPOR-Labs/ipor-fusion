// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessManagedUpgradeable} from "../access/AccessManagedUpgradeable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPlasmaVault} from "../../interfaces/IPlasmaVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FeeAccount} from "./FeeAccount.sol";
import {PlasmaVaultGovernance} from "../../vaults/PlasmaVaultGovernance.sol";
import {RecipientFee} from "./FeeManagerFactory.sol";
import {FeeManagerStorageLib, FeeRecipientDataStorage} from "./FeeManagerStorageLib.sol";
import {ContextClient} from "../context/ContextClient.sol";
import {HighWaterMarkPerformanceFeeStorage} from "./FeeManagerStorageLib.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Struct containing initialization data for the fee manager
/// @param initialAuthority Address of the initial authority
/// @param plasmaVault Address of the plasma vault
/// @param iporDaoManagementFee Management fee percentage for the DAO (in percentage with 2 decimals, example 10000 is 100%, 100 is 1%)
/// @param iporDaoPerformanceFee Performance fee percentage for the DAO (in percentage with 2 decimals, example 10000 is 100%, 100 is 1%)
/// @param iporDaoFeeRecipientAddress Address of the DAO fee recipient
/// @param recipientManagementFees Array of recipient management fees, must not contain duplicate recipient addresses
/// @param recipientPerformanceFees Array of recipient performance fees, must not contain duplicate recipient addresses
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
    using SafeCast for uint256;
    event HarvestManagementFee(address receiver, uint256 amount);
    event HarvestPerformanceFee(address receiver, uint256 amount);
    event PerformanceFeeUpdated(uint256 totalFee, address[] recipients, uint256[] fees);
    event ManagementFeeUpdated(uint256 totalFee, address[] recipients, uint256[] fees);
    event FeeAccountDeployed(address performanceFeeAccount, address managementFeeAccount);

    /// @notice Thrown when trying to call a function before initialization
    error NotInitialized();

    /// @notice Thrown when trying to initialize an already initialized contract
    error AlreadyInitialized();

    /// @notice Thrown when trying to set an invalid (zero) address as a fee recipient
    error InvalidFeeRecipientAddress();

    /// @notice Thrown when a recipient address appears more than once in the same recipient fee array
    error DuplicateFeeRecipientAddress(address recipient);

    /// @notice Thrown when trying to set an invalid authority
    error InvalidAuthority();

    /// @notice Thrown when trying to set an invalid high water mark
    error InvalidHighWaterMark();

    /// @notice Thrown when the manual high water mark reset would raise the stored high water mark (IL-9667)
    /// @param currentHighWaterMark Current share rate of the vault in the high water mark unit
    /// @param storedHighWaterMark High water mark stored before the reset
    error HighWaterMarkResetAboveStored(uint256 currentHighWaterMark, uint256 storedHighWaterMark);

    /// @notice Thrown when trying to call a function from a non-plasma vault contract
    error NotPlasmaVault();

    /// @notice Thrown when the deposit fee exceeds DEPOSIT_MAX_FEE_IN_PERCENTAGE
    error InvalidDepositFee(uint256 fee);

    /// @notice Thrown when the management fee is changed while a realization would still mint fee shares
    /// @param unrealizedManagementFee Unrealized management fee of the plasma vault, in underlying asset units
    error FeeManagerUnrealizedManagementFee(uint256 unrealizedManagementFee);

    uint64 private constant INITIALIZED_VERSION = 10;

    /// @dev Hard CAP for the deposit fee, WAD-scaled (1e18 = 100%) - 10%
    uint256 public constant DEPOSIT_MAX_FEE_IN_PERCENTAGE = 1e17;

    /// @notice Scale of the share rate and of the high-water mark (IL-9601)
    /// @dev The vault passes the rate as assets per 10 ** decimals() shares multiplied by this scale, and the
    ///      high-water mark is stored in the same unit: on a 6-decimal asset one unit is 1e-18 of the share price
    ///      instead of 1e-6, so the floored post-fee mark no longer charges the same asset unit again (Olympix M11).
    ///      A FeeManager without this constant stores asset units per 10 ** decimals() shares; it must be paired
    ///      only with a vault built before IL-9601, and this one only with a vault that passes the scaled rate.
    uint256 public constant HIGH_WATER_MARK_SCALE = FeeManagerStorageLib.HIGH_WATER_MARK_SCALE;

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

                if (initData_.recipientManagementFees[i].recipient == address(0)) {
                    revert InvalidFeeRecipientAddress();
                }

                _revertIfDuplicateRecipient(
                    managementFeeRecipientAddresses,
                    i,
                    initData_.recipientManagementFees[i].recipient
                );

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

                if (initData_.recipientPerformanceFees[i].recipient == address(0)) {
                    revert InvalidFeeRecipientAddress();
                }

                _revertIfDuplicateRecipient(
                    performanceFeeRecipientAddresses,
                    i,
                    initData_.recipientPerformanceFees[i].recipient
                );

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

        emit FeeAccountDeployed(PERFORMANCE_FEE_ACCOUNT, MANAGEMENT_FEE_ACCOUNT);
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
        _updateHighWaterMarkPerformanceFee();
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
    /// @dev The harvest covers only shares already minted to the management fee account. A fee accrued since the
    /// last realization that would mint at least one share blocks the update (see the revert below), so the old
    /// period is paid to the old recipients. Only a remainder that mints no share (dust) stays pending and is split
    /// by the NEW recipients when it is minted later. With a new total of 0 shares already minted wait in the
    /// account until a non-zero fee is configured.
    /// @dev Reverts with FeeManagerUnrealizedManagementFee while the vault has shares and assets and its unrealized
    /// management fee would still mint at least one fee share (same convertToShares as the vault's realization), so
    /// the old period is always split by the old recipients. Realize the fee first (any deposit, mint, withdraw or
    /// redeem in the same batch). Vaults without shares or without assets are skipped, as in the vault's checkpoint.
    /// If none of deposit, mint, withdraw or redeem can run (supply cap reached, reverting deposit pre-hook, users
    /// paused, atomist without deposit access), every update reverts, also a cut to 0 or a recipient removal: restore
    /// one of these paths first in the same batch (raise the supply cap, grant the deposit role or whitelist, unpause),
    /// then realize the fee, then change it.
    /// @dev Total management fee will be the sum of all recipient fees + DAO fee
    /// @dev Reverts with DuplicateFeeRecipientAddress if recipientFees contains a repeated recipient address
    /// @param recipientFees Array of recipient fees containing address and new fee value, no duplicate addresses allowed
    /// @custom:access Restricted to ATOMIST_ROLE
    function updateManagementFee(RecipientFee[] calldata recipientFees) external restricted {
        if (IERC4626(PLASMA_VAULT).totalSupply() != 0 && IERC4626(PLASMA_VAULT).totalAssets() != 0) {
            uint256 unrealizedManagementFee = IPlasmaVault(PLASMA_VAULT).getUnrealizedManagementFee();
            if (IERC4626(PLASMA_VAULT).convertToShares(unrealizedManagementFee) != 0) {
                revert FeeManagerUnrealizedManagementFee(unrealizedManagementFee);
            }
        }
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
    /// @dev IL-9632 (Olympix L01): first crystallizes the performance fee at the old rate
    ///      (PlasmaVault.realizePerformanceFee), then harvests the performance fee account with the old recipient
    ///      split, then writes the new recipients and total. The gain above the high-water mark earned before the
    ///      change is therefore charged at the old rate and paid to the old recipients, and the new rate applies only
    ///      to the gain above the high-water mark after this call. The crystallization is the vault's regular one: it
    ///      prices the stored market balances (refresh the markets first in the same batch so that an unbooked gain
    ///      is charged at the old rate too), lowers the high-water mark after the update interval when the rate is
    ///      below it, and sets the mark only to the rate after the fee mint, never to a stored mark above the rate
    ///      (no conflict with the manual reset rule of updateHighWaterMarkPerformanceFee, IL-9667). Needs a vault
    ///      built with IL-9632 (the pair from the factory); on a vault without realizePerformanceFee the call reverts.
    /// @dev Total performance fee will be the sum of all recipient fees + DAO fee
    /// @dev Reverts with DuplicateFeeRecipientAddress if recipientFees contains a repeated recipient address
    /// @param recipientFees Array of recipient fees containing address and new fee value, no duplicate addresses allowed
    /// @custom:access Restricted to ATOMIST_ROLE
    function updatePerformanceFee(RecipientFee[] calldata recipientFees) external restricted {
        /// @dev IL-9632: crystallize at the old rate before the harvest, so the minted shares go to the old split
        IPlasmaVault(PLASMA_VAULT).realizePerformanceFee();
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
    /// @dev Reverts with DuplicateFeeRecipientAddress if recipientFees contains a repeated recipient address
    /// @param recipientFees Array of recipient fees containing address and new fee value, no duplicate addresses allowed
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

            _revertIfDuplicateRecipient(newRecipients, i, recipientFees[i].recipient);

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

    /// @notice Updates the high water mark (HWM) for performance fee calculation to the current exchange rate
    /// @dev This function should be called to synchronize the HWM with the current vault state.
    ///      The HWM is used to ensure that performance fees are only charged on new profits above the HWM (the share price after the last performance fee).
    ///      Only callable by addresses with the `restricted` modifier (e.g., governance or automation).
    ///      The new HWM is set to the current asset value per share (exchange rate) of the vault, in the unit of the
    ///      rate the vault passes: `convertToAssets(10 ** decimals() * HIGH_WATER_MARK_SCALE)` (IL-9601).
    ///      Reverts if the current exchange rate is zero (prevents setting an invalid HWM), and with the SafeCast
    ///      error if the scaled rate does not fit uint128 (the vault skips the performance fee in that range).
    /// @custom:security Only callable by authorized roles to prevent manipulation.
    /// @custom:security Ensures HWM cannot be set to zero, which would allow fee abuse.
    /// @custom:security Lowering (IL-9637, Olympix L06): the reset also sets the HWM below the stored mark. This is the
    ///      "Reset high watermark" feature (IL-6921), so that a vault accrues performance fees again after a large
    ///      drop of the share price; the recovery from the current rate back to the old mark is then charged again.
    ///      Depositors are protected by the execution delay of the OWNER_ROLE grant, the role the IPOR Fusion
    ///      initializer maps to this function: an owner granted with a non-zero delay has to schedule the reset in the
    ///      access manager and can execute it only after the delay, GUARDIAN_ROLE can cancel it in between. The
    ///      initializer grants OWNER_ROLE with a zero delay, so by default the reset takes effect immediately.
    /// @custom:security Raising (IL-9667, Olympix L36): reverts with HighWaterMarkResetAboveStored when the stored HWM
    ///      is not zero and the current rate is above it. A rate above the HWM is a gain that is not crystallized
    ///      yet: the next execute, updateMarketsBalances, withdraw or redeem charges the performance fee on it, the
    ///      IPOR DAO share included, and moves the HWM itself, so raising the HWM by hand could only waive that fee
    ///      (IL-8120). Crystallize first, then reset. A rate equal to or below the HWM is stored as before, and a
    ///      zero stored HWM (not initialized) is set to any non-zero rate.
    /// @custom:see EIP-4626 for vault fee patterns and best practices.
    function updateHighWaterMarkPerformanceFee() external restricted {
        uint256 storedHighWaterMark = FeeManagerStorageLib.getPlasmaVaultHighWaterMarkPerformanceFee().highWaterMark;
        _updateHighWaterMarkPerformanceFee();
        /// @dev IL-9667: checked on the stored result, so the rate is converted once, in the unit the HWM is kept in;
        ///      the revert undoes the write
        uint256 newHighWaterMark = FeeManagerStorageLib.getPlasmaVaultHighWaterMarkPerformanceFee().highWaterMark;
        if (storedHighWaterMark != 0 && newHighWaterMark > storedHighWaterMark) {
            revert HighWaterMarkResetAboveStored(newHighWaterMark, storedHighWaterMark);
        }
    }

    /// @notice Updates the minimum interval between high water mark (HWM) updates for performance fee calculation
    /// @dev This function sets the minimum time (in seconds) that must elapse before the HWM can be updated again.
    ///      The interval helps prevent frequent HWM updates, which could be exploited to reduce or avoid performance fees.
    ///      Only callable by addresses with the `restricted` modifier (e.g., governance or automation).
    ///      Setting the interval to zero disables automatic HWM lowering during downtrends in
    ///      `calculateAndUpdatePerformanceFee`. When disabled, the HWM remains at the historical peak
    ///      until manually updated via `updateHighWaterMarkPerformanceFee`.
    ///      Setting a non-zero interval enables automatic HWM lowering: if the exchange rate is below the HWM
    ///      and the interval has elapsed since the last update, the HWM is automatically lowered to the current rate.
    /// @param updateInterval_ The new minimum update interval in seconds. Zero disables automatic HWM lowering.
    /// @custom:security Only callable by authorized roles to prevent manipulation.
    /// @custom:security Setting a reasonable interval is important to mitigate fee gaming and ensure fair accrual.
    /// @custom:see EIP-4626 for vault fee patterns and best practices.
    function updateIntervalHighWaterMarkPerformanceFee(uint32 updateInterval_) external restricted {
        FeeManagerStorageLib.updateIntervalHighWaterMarkPerformanceFee(updateInterval_);
    }

    /// @notice Sets the deposit fee percentage for the plasma vault
    /// @dev This function configures the deposit fee that will be charged on all new deposits
    ///      to the plasma vault. The fee is calculated as a percentage of the deposited assets
    ///      and is deducted from the user's deposit amount before minting shares.
    ///
    /// @param fee_ Deposit fee percentage with 18 decimal precision (1e18 = 100%, 1e16 = 1%)
    ///              Must not exceed DEPOSIT_MAX_FEE_IN_PERCENTAGE (1e17 = 10%); reverts with
    ///              InvalidDepositFee otherwise
    ///
    /// @dev Flow:
    /// 1. Reverts with InvalidDepositFee if fee_ > DEPOSIT_MAX_FEE_IN_PERCENTAGE
    /// 2. Updates the deposit fee in storage via FeeManagerStorageLib
    /// 3. The new fee will apply to all subsequent deposits
    ///
    /// @custom:access Restricted to authorized roles (ATOMIST_ROLE)
    /// @custom:security Fee should be reasonable to maintain vault attractiveness
    /// @custom:security Fee is deducted from user deposits, not added on top
    /// @custom:see EIP-4626 for vault fee patterns and best practices
    /// @custom:example Setting fee_ to 1e16 (1e18 * 0.01) sets a 1% deposit fee
    function setDepositFee(uint256 fee_) external restricted {
        if (fee_ > DEPOSIT_MAX_FEE_IN_PERCENTAGE) {
            revert InvalidDepositFee(fee_);
        }
        FeeManagerStorageLib.setPlasmaVaultDepositFee(fee_);
    }

    /// @notice Calculates performance fee based on high water mark mechanism
    /// @dev This function implements a high water mark (HWM) based performance fee calculation
    ///      where fees are only charged on gains above the HWM (the share price after the last performance fee).
    ///      The function can only be called by the plasma vault contract.
    ///
    /// @param actualExchangeRate_ Current exchange rate between shares and assets: assets per 10 ** shareDecimals
    ///        shares multiplied by HIGH_WATER_MARK_SCALE (IL-9601), the unit of the stored HWM. The vault computes it
    ///        in one mulDiv from the terms of its net share price, not by scaling an already rounded rate.
    /// @param totalSupply_ Total supply of vault shares
    /// @param performanceFee_ Performance fee percentage with 2 decimal precision (10000 = 100%)
    /// @param assetDecimals_ Decimals of the underlying asset (share decimals minus the vault decimals offset).
    ///        Used only to price the share rate after the fee mint; actualExchangeRate_ is not normalized and
    ///        callers must ensure it is already in share-consistent units.
    ///
    /// @return recipient Address of the performance fee recipient (PERFORMANCE_FEE_ACCOUNT or address(0))
    /// @return feeShares Number of shares to be minted as performance fee
    ///
    /// @dev Flow:
    /// 1. If HWM is 0 (first time), sets HWM to current rate and returns 0 fee
    /// 2. If current rate is below HWM:
    ///    - If updateInterval is 0 (disabled): no automatic HWM update, returns 0 fee
    ///    - If updateInterval > 0 and interval not yet passed: returns 0 fee
    ///      (IL-9636: `lastUpdate + updateInterval` is summed in uint256, so a large interval cannot overflow)
    ///    - If updateInterval > 0 and interval has passed: updates HWM to current rate and returns 0 fee
    /// 3. If current rate is above HWM:
    ///    - Calculates the fee shares that are worth performanceFee_ of the gain above HWM after their own mint
    ///      (IL-8870): totalSupply_ * f / (10000 * rate - f) with f = performanceFee_ * (rate - HWM)
    ///    - Sets HWM to the share price after the fee mint (IL-8744); if no fee shares result, to the current rate
    ///    - Returns fee recipient and calculated shares
    /// 4. The rate, the HWM and the price after the mint are all in the HIGH_WATER_MARK_SCALE unit (IL-9601). The
    ///    fee share formula is a ratio of rates, so the scale changes only the precision of rate - HWM.
    ///
    /// @custom:security Uses SafeCast for uint256 to uint128 conversion
    /// @custom:security Implements reentrancy protection via plasma vault pattern
    /// @custom:security Only callable by plasma vault to prevent unauthorized fee generation
    function calculateAndUpdatePerformanceFee(
        uint128 actualExchangeRate_,
        uint256 totalSupply_,
        uint256 performanceFee_,
        uint256 assetDecimals_
    ) external returns (address recipient, uint256 feeShares) {
        if (msg.sender != PLASMA_VAULT) {
            revert NotPlasmaVault();
        }

        HighWaterMarkPerformanceFeeStorage memory highWaterMarkStorage = FeeManagerStorageLib
            .getPlasmaVaultHighWaterMarkPerformanceFee();

        if (highWaterMarkStorage.highWaterMark == 0) {
            FeeManagerStorageLib.updateHighWaterMarkPerformanceFee(actualExchangeRate_);
            return (address(0), 0);
        }

        if (actualExchangeRate_ <= highWaterMarkStorage.highWaterMark) {
            if (
                highWaterMarkStorage.updateInterval != 0 &&
                block.timestamp >=
                    uint256(highWaterMarkStorage.lastUpdate) + uint256(highWaterMarkStorage.updateInterval)
            ) {
                FeeManagerStorageLib.updateHighWaterMarkPerformanceFee(actualExchangeRate_);
            }
            return (address(0), 0);
        }

        uint256 delta = actualExchangeRate_ - uint256(highWaterMarkStorage.highWaterMark);
        /// @dev IL-8870: the fee shares are worth performanceFee_ of the gain after their own mint. With
        ///      x = performanceFee_ * delta / (10000 * actualExchangeRate_), the fee as a part of the vault value,
        ///      the shares are x / (1 - x) of the supply: feeShares / (totalSupply_ + feeShares) = x, and the share
        ///      price after the mint is the rate less performanceFee_ of the gain. x of the supply (shares priced
        ///      before their own mint) is worth only x / (1 + x) after it. delta is below the rate and the vault
        ///      caps performanceFee_ at 50%, so the denominator is positive and the result is below totalSupply_.
        uint256 feeValue = delta * performanceFee_;
        feeShares = Math.mulDiv(totalSupply_, feeValue, uint256(actualExchangeRate_) * 10000 - feeValue);

        /// @dev IL-8744: the HWM is the share price after the fee shares are minted (the vault mints right after this
        ///      call), not the pre-mint rate; otherwise the recovery from the diluted price back to the pre-mint rate
        ///      would be fee-free and the effective fee would converge to p / (1 + p)
        FeeManagerStorageLib.updateHighWaterMarkPerformanceFee(
            feeShares == 0 ? actualExchangeRate_ : _rateAfterFeeMint(totalSupply_ + feeShares, assetDecimals_)
        );
        return (PERFORMANCE_FEE_ACCOUNT, feeShares);
    }

    /// @notice Performance fee shares that calculateAndUpdatePerformanceFee sizes for the same inputs now, without
    ///         writing anything
    /// @dev IL-9624 (Olympix M34): the vault's previewRedeem, previewWithdraw, maxWithdraw and, with released request
    ///      shares (IL-9624 follow-up), maxRedeem call this to price the performance fee that withdraw and redeem
    ///      crystallize before they pay, so the views equal the results on fresh market balances (ERC-4626: a
    ///      preview must not promise more than the call gives). Mirrors
    ///      calculateAndUpdatePerformanceFee branch by branch: 0 while the high-water mark is not set (the first
    ///      crystallization only stores it) and when the rate is at or below the mark (also after the update
    ///      interval, where the crystallization lowers the mark without a fee); above the mark the same IL-8870
    ///      formula, totalSupply_ * f / (10000 * rate - f) with f = performanceFee_ * (rate - HWM). The formula is
    ///      repeated here rather than shared through a private function, so the crystallization path keeps its gas;
    ///      PlasmaVaultPreviewPerformanceFeeTest asserts that both size the same shares.
    /// @dev Gas: the selector (0xa6d84657) sorts after calculateAndUpdatePerformanceFee (0x9617bcca); with the linear
    ///      selector dispatch of the repository profile (optimizer runs 2) the new function adds nothing to the
    ///      crystallization call of execute, updateMarketsBalances, withdraw and redeem.
    /// @dev The PlasmaVault and the FeeManager are a pair from the factory: a PlasmaVault built with IL-9624 calls this
    ///      function in those views (maxRedeem only with released request shares), which revert on a FeeManager built
    ///      before it.
    /// @param actualExchangeRate_ Share rate in the HIGH_WATER_MARK_SCALE unit, the value the vault would pass to
    ///        calculateAndUpdatePerformanceFee
    /// @param totalSupply_ Share supply the fee is sized on: the minted supply plus the virtual management fee shares
    /// @param performanceFee_ Performance fee percentage with 2 decimal precision (10000 = 100%)
    /// @return feeShares Performance fee shares the vault would mint on top of totalSupply_
    function pendingPerformanceFeeShares(
        uint128 actualExchangeRate_,
        uint256 totalSupply_,
        uint256 performanceFee_
    ) external view returns (uint256 feeShares) {
        uint256 highWaterMark = FeeManagerStorageLib.getPlasmaVaultHighWaterMarkPerformanceFee().highWaterMark;
        if (highWaterMark == 0 || actualExchangeRate_ <= highWaterMark) {
            return 0;
        }
        uint256 feeValue = (actualExchangeRate_ - highWaterMark) * performanceFee_;
        feeShares = Math.mulDiv(totalSupply_, feeValue, uint256(actualExchangeRate_) * 10000 - feeValue);
    }

    /// @notice Share price right after fee shares were minted on top of the current supply
    /// @dev Mirrors PlasmaVault.convertToAssets(10 ** decimals() * HIGH_WATER_MARK_SCALE) evaluated with
    ///      supply = supplyAfterMint_ (Floor): mulDiv(10 ** shareDecimals * HIGH_WATER_MARK_SCALE, totalAssets + 1,
    ///      supplyAfterMint_ + 10 ** (shareDecimals - assetDecimals)), where 10 ** (shareDecimals - assetDecimals)
    ///      is the vault share scale multiplier. Minting fee shares does not change totalAssets, so the value is
    ///      exact; with the scale (IL-9601) the floor drops less than 1e-12 of an asset unit per share. The result
    ///      never exceeds the pre-mint rate, which the vault guarantees fits uint128.
    /// @param supplyAfterMint_ Vault share supply including the performance fee shares about to be minted
    /// @param assetDecimals_ Decimals of the underlying asset (share decimals minus the vault decimals offset)
    /// @return Assets per 10 ** shareDecimals shares times HIGH_WATER_MARK_SCALE after the mint, as stored in the HWM
    function _rateAfterFeeMint(uint256 supplyAfterMint_, uint256 assetDecimals_) private view returns (uint128) {
        uint256 shareDecimals = IERC20Metadata(PLASMA_VAULT).decimals();
        return
            Math
                .mulDiv(
                    10 ** shareDecimals * HIGH_WATER_MARK_SCALE,
                    IERC4626(PLASMA_VAULT).totalAssets() + 1,
                    supplyAfterMint_ + 10 ** (shareDecimals - assetDecimals_)
                )
                .toUint128();
    }

    /// @notice Calculates the deposit fee for a given amount of assets
    /// @dev This function calculates the deposit fee based on the configured deposit fee percentage
    ///      and the amount of assets being deposited. The deposit fee is calculated as a percentage
    ///      of the deposited assets using 18 decimal precision (1e18 = 100%, 1e16 = 1%).
    ///
    /// @param shares_ The amount of shares being deposited (in share units)
    ///
    /// @return The calculated deposit fee amount (in share units)
    ///
    /// @dev Flow:
    /// 1. Retrieves the current deposit fee percentage from storage
    /// 2. If deposit fee is 0, returns 0 (no fee)
    /// 3. Calculates fee using Math.mulDiv for precision: (shares_ * depositFee) / 1e18
    ///
    /// @custom:security Uses Math.mulDiv to prevent overflow and maintain precision
    /// @custom:security View function - no state changes, safe for external calls
    /// @custom:see EIP-4626 for vault fee patterns and best practices
    /// @custom:example If depositFee is 1e16 (1%) and shares_ is 1000e18, returns 10e18
    function calculateDepositFee(uint256 shares_) external view returns (uint256) {
        uint256 depositFee = FeeManagerStorageLib.getPlasmaVaultDepositFee();
        if (depositFee == 0) {
            return 0;
        }
        return Math.mulDiv(shares_, depositFee, 1e18);
    }

    /// @notice Gets the current deposit fee percentage for the plasma vault
    /// @dev This function retrieves the currently configured deposit fee percentage
    ///      that will be applied to all new deposits. The fee is returned in 18 decimal
    ///      precision format where 1e18 represents 100% and 1e16 represents 1%.
    ///
    /// @return The current deposit fee percentage with 18 decimal precision
    ///         (1e18 = 100%, 1e16 = 1%, 0 = no fee)
    ///
    /// @dev Flow:
    /// 1. Retrieves the deposit fee from storage via FeeManagerStorageLib
    /// 2. Returns the raw fee value without any calculations
    ///
    /// @custom:security View function - no state changes, safe for external calls
    /// @custom:security Returns the raw fee percentage, not the calculated fee amount
    /// @custom:see EIP-4626 for vault fee patterns and best practices
    /// @custom:example If deposit fee is 1%, returns 1e16 (1e18 * 0.01)
    function getDepositFee() external view returns (uint256) {
        return FeeManagerStorageLib.getPlasmaVaultDepositFee();
    }

    /// @notice Returns the high-water mark, its last update time and the update interval
    /// @dev `highWaterMark` is assets per 10 ** decimals() vault shares multiplied by HIGH_WATER_MARK_SCALE (1e12),
    ///      IL-9601. Divide by HIGH_WATER_MARK_SCALE for asset units per 10 ** decimals() shares. A FeeManager
    ///      without HIGH_WATER_MARK_SCALE (built before IL-9601) returns asset units per 10 ** decimals() shares.
    /// @return The high-water mark storage
    function getPlasmaVaultHighWaterMarkPerformanceFee()
        external
        view
        returns (HighWaterMarkPerformanceFeeStorage memory)
    {
        return FeeManagerStorageLib.getPlasmaVaultHighWaterMarkPerformanceFee();
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

            if (recipientShare > 0) {
                IERC4626(PLASMA_VAULT).transferFrom(feeAccount_, recipient_, recipientShare);
                _emitHarvestEvent(recipient_, recipientShare, feeType_);
            }
        }

        return remainingBalance_;
    }

    /// @notice Reverts when recipient_ already appears among recipients_[0..count_)
    /// @dev Used by the constructor loops and _updateFees to reject duplicate recipient addresses
    /// @param recipients_ The in-progress array of recipient addresses already validated in this call
    /// @param count_ Number of entries in recipients_ that are already populated and must be checked
    /// @param recipient_ The recipient address about to be added
    function _revertIfDuplicateRecipient(
        address[] memory recipients_,
        uint256 count_,
        address recipient_
    ) private pure {
        for (uint256 j; j < count_; j++) {
            if (recipients_[j] == recipient_) {
                revert DuplicateFeeRecipientAddress(recipient_);
            }
        }
    }

    /// @notice Sets the HWM to the vault's current share rate in the HWM unit
    /// @dev One conversion in the vault, convertToAssets(10 ** decimals() * HIGH_WATER_MARK_SCALE): the same mulDiv
    ///      and the same net terms as the rate the vault passes to calculateAndUpdatePerformanceFee (IL-9601).
    function _updateHighWaterMarkPerformanceFee() private {
        uint256 highWaterMark = IERC4626(PLASMA_VAULT).convertToAssets(
            10 ** uint256(IERC20Metadata(PLASMA_VAULT).decimals()) * HIGH_WATER_MARK_SCALE
        );
        if (highWaterMark > 0) {
            FeeManagerStorageLib.updateHighWaterMarkPerformanceFee(highWaterMark.toUint128());
        } else {
            revert InvalidHighWaterMark();
        }
    }

    /// @notice Internal function to get the message sender from context
    /// @return The address of the message sender
    function _msgSender() internal view override returns (address) {
        return _getSenderFromContext();
    }
}

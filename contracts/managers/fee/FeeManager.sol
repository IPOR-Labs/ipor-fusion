// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {AccessManagedUpgradeable} from "../access/AccessManagedUpgradeable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {AuthorityUtils} from "@openzeppelin/contracts/access/manager/AuthorityUtils.sol";
import {FeeAccount} from "./FeeAccount.sol";
import {PlasmaVaultGovernance} from "../../vaults/PlasmaVaultGovernance.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {FeeManagerStorageLib, FeeManagerStorage} from "./FeeManagerStorageLib.sol";
import {ContextClient} from "../context/ContextClient.sol";

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

/// @title FeeManager
/// @notice Manages the fees for the IporFusion protocol, including management and performance fees.
/// @dev Inherits from AccessManaged for access control.
contract FeeManager is AccessManagedUpgradeable, ContextClient {
    event HarvestManagementFee(address receiver, uint256 amount);
    event HarvestPerformanceFee(address receiver, uint256 amount);
    event PerformanceFeeUpdated(uint256 newPerformanceFee);
    event ManagementFeeUpdated(uint256 newManagementFee);

    error NotInitialized();
    error AlreadyInitialized();
    error InvalidFeeRecipientAddress();

    function getFeeConfig() external view returns (FeeManagerStorage memory) {
        return FeeManagerStorageLib.getFeeConfig();
    }

    /// @notice PERFORMANCE_FEE_ACCOUNT is the address of the performance fee account where the performance fee is collected before being transferred to the IPOR DAO and the Fee Recipient by the harvestPerformanceFee function
    address public immutable PERFORMANCE_FEE_ACCOUNT;
    /// @notice MANAGEMENT_FEE_ACCOUNT is the address of the management fee account where the management fee is collected before being transferred to the IPOR DAO and the Fee Recipient by the harvestManagementFee function
    address public immutable MANAGEMENT_FEE_ACCOUNT;
    /// @notice IPOR_DAO_MANAGEMENT_FEE is in percentage with 2 decimals, example 10000 is 100%, 100 is 1%. It is the management fee percentage for the IPOR DAO.
    uint256 public immutable IPOR_DAO_MANAGEMENT_FEE;
    /// @notice IPOR_DAO_PERFORMANCE_FEE is in percentage with 2 decimals, example 10000 is 100%, 100 is 1%. It is the performance fee percentage for the DAO.
    uint256 public immutable IPOR_DAO_PERFORMANCE_FEE;

    address public immutable PLASMA_VAULT;

    uint64 private constant INITIALIZED_VERSION = 10;

    constructor(FeeManagerInitData memory initData_) initializer {
        super.__AccessManaged_init_unchained(initData_.initialAuthority);

        PERFORMANCE_FEE_ACCOUNT = address(new FeeAccount(address(this)));
        MANAGEMENT_FEE_ACCOUNT = address(new FeeAccount(address(this)));

        IPOR_DAO_MANAGEMENT_FEE = initData_.iporDaoManagementFee;
        IPOR_DAO_PERFORMANCE_FEE = initData_.iporDaoPerformanceFee;

        FeeManagerStorageLib.setPlasmaVaultPerformanceFee(initData_.atomistPerformanceFee + IPOR_DAO_PERFORMANCE_FEE);
        FeeManagerStorageLib.setPlasmaVaultManagementFee(initData_.atomistManagementFee + IPOR_DAO_MANAGEMENT_FEE);

        FeeManagerStorageLib.setFeeRecipientAddress(initData_.feeRecipientAddress);
        FeeManagerStorageLib.setIporDaoFeeRecipientAddress(initData_.iporDaoFeeRecipientAddress);

        PLASMA_VAULT = initData_.plasmaVault;
    }

    function initialize() external reinitializer(INITIALIZED_VERSION) {
        FeeAccount(PERFORMANCE_FEE_ACCOUNT).approveMaxForFeeManager(PLASMA_VAULT);
        FeeAccount(MANAGEMENT_FEE_ACCOUNT).approveMaxForFeeManager(PLASMA_VAULT);
    }

    /// @notice Harvests the management fee and transfers it to the respective recipient addresses.
    /// @dev This function can only be called if the contract is initialized.
    /// It checks if the fee recipient addresses are valid and then calculates the amount to be transferred to the DAO
    /// and the remaining amount to the fee recipient. The function emits events for each transfer.
    /// @custom:modifier onlyInitialized Ensures the contract is initialized before executing the function.
    function harvestManagementFee() public onlyInitialized {
        if (
            FeeManagerStorageLib.getFeeRecipientAddress() == address(0) ||
            FeeManagerStorageLib.getIporDaoFeeRecipientAddress() == address(0)
        ) {
            revert InvalidFeeRecipientAddress();
        }

        if (FeeManagerStorageLib.getPlasmaVaultManagementFee() == 0) {
            return;
        }

        uint256 balance = IERC4626(PLASMA_VAULT).balanceOf(MANAGEMENT_FEE_ACCOUNT);

        if (balance == 0) {
            return;
        }

        uint256 decimals = IERC4626(PLASMA_VAULT).decimals();
        uint256 numberOfDecimals = 10 ** (decimals);

        uint256 percentageToTransferToDao = (IPOR_DAO_MANAGEMENT_FEE * numberOfDecimals) /
            FeeManagerStorageLib.getPlasmaVaultManagementFee();

        uint256 transferAmountToDao = Math.mulDiv(balance, percentageToTransferToDao, numberOfDecimals);

        IERC4626(PLASMA_VAULT).transferFrom(
            MANAGEMENT_FEE_ACCOUNT,
            FeeManagerStorageLib.getIporDaoFeeRecipientAddress(),
            transferAmountToDao
        );
        emit HarvestManagementFee(FeeManagerStorageLib.getIporDaoFeeRecipientAddress(), transferAmountToDao);

        if (balance <= transferAmountToDao) {
            return;
        }

        uint256 transferAmount = balance - transferAmountToDao;

        if (transferAmount == 0) {
            return;
        }

        IERC4626(PLASMA_VAULT).transferFrom(
            MANAGEMENT_FEE_ACCOUNT,
            FeeManagerStorageLib.getFeeRecipientAddress(),
            transferAmount
        );
        emit HarvestManagementFee(FeeManagerStorageLib.getFeeRecipientAddress(), balance - transferAmountToDao);
    }

    /// @notice Harvests the performance fee and transfers it to the respective recipient addresses.
    /// @dev This function can only be called if the contract is initialized.
    /// It checks if the fee recipient addresses are valid and then calculates the amount to be transferred to the DAO
    /// and the remaining amount to the fee recipient. The function emits events for each transfer.
    /// @custom:modifier onlyInitialized Ensures the contract is initialized before executing the function.
    function harvestPerformanceFee() public onlyInitialized {
        if (
            FeeManagerStorageLib.getFeeRecipientAddress() == address(0) ||
            FeeManagerStorageLib.getIporDaoFeeRecipientAddress() == address(0)
        ) {
            revert InvalidFeeRecipientAddress();
        }

        if (FeeManagerStorageLib.getPlasmaVaultPerformanceFee() == 0) {
            return;
        }

        uint256 balance = IERC4626(PLASMA_VAULT).balanceOf(PERFORMANCE_FEE_ACCOUNT);

        if (balance == 0) {
            return;
        }

        uint256 decimals = IERC4626(PLASMA_VAULT).decimals();
        uint256 numberOfDecimals = 10 ** (decimals);

        uint256 percentToTransferToDao = (IPOR_DAO_PERFORMANCE_FEE * numberOfDecimals) /
            FeeManagerStorageLib.getPlasmaVaultPerformanceFee();

        uint256 transferAmountToDao = Math.mulDiv(balance, percentToTransferToDao, numberOfDecimals);

        IERC4626(PLASMA_VAULT).transferFrom(
            PERFORMANCE_FEE_ACCOUNT,
            FeeManagerStorageLib.getIporDaoFeeRecipientAddress(),
            transferAmountToDao
        );
        emit HarvestPerformanceFee(FeeManagerStorageLib.getIporDaoFeeRecipientAddress(), transferAmountToDao);

        if (balance <= transferAmountToDao) {
            return;
        }

        uint256 transferAmount = balance - transferAmountToDao;

        if (transferAmount == 0) {
            return;
        }

        IERC4626(PLASMA_VAULT).transferFrom(
            PERFORMANCE_FEE_ACCOUNT,
            FeeManagerStorageLib.getFeeRecipientAddress(),
            balance - transferAmountToDao
        );
        emit HarvestPerformanceFee(FeeManagerStorageLib.getFeeRecipientAddress(), balance - transferAmountToDao);
    }

    /**
     * @notice Updates the performance fee and reconfigures it in the PlasmaVaultGovernance contract.
     * @param performanceFee_ The new performance fee to be added to the DAO performance fee.
     */
    function updatePerformanceFee(uint256 performanceFee_) external restricted {
        harvestPerformanceFee();

        uint256 newPerformanceFee = performanceFee_ + IPOR_DAO_PERFORMANCE_FEE;

        PlasmaVaultGovernance(PLASMA_VAULT).configurePerformanceFee(PERFORMANCE_FEE_ACCOUNT, newPerformanceFee);
        FeeManagerStorageLib.setPlasmaVaultPerformanceFee(newPerformanceFee);

        emit PerformanceFeeUpdated(newPerformanceFee);
    }

    /// @notice Updates the management fee and reconfigures it in the PlasmaVaultGovernance contract.
    /// @param managementFee_ The new management fee to be added to the DAO management fee.
    function updateManagementFee(uint256 managementFee_) external restricted {
        harvestManagementFee();

        uint256 newManagementFee = managementFee_ + IPOR_DAO_MANAGEMENT_FEE;

        PlasmaVaultGovernance(PLASMA_VAULT).configureManagementFee(MANAGEMENT_FEE_ACCOUNT, newManagementFee);
        FeeManagerStorageLib.setPlasmaVaultManagementFee(newManagementFee);

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

        FeeManagerStorageLib.setFeeRecipientAddress(feeRecipientAddress_);
    }

    /**
     * @notice Sets the address of the DAO fee recipient.
     * @dev This function can only be called by an authorized account (IPOR_DAO_ROLE).
     * @param iporDaoFeeRecipientAddress_ The address to set as the DAO fee recipient.
     * @custom:error InvalidAddress Thrown if the provided address is the zero address.
     */
    function setIporDaoFeeRecipientAddress(address iporDaoFeeRecipientAddress_) external restricted {
        if (iporDaoFeeRecipientAddress_ == address(0)) {
            revert Errors.WrongAddress();
        }

        FeeManagerStorageLib.setIporDaoFeeRecipientAddress(iporDaoFeeRecipientAddress_);
    }

    modifier onlyInitialized() {
        if (_getInitializedVersion() != INITIALIZED_VERSION) {
            revert NotInitialized();
        }
        _;
    }

    function _msgSender() internal view override returns (address) {
        return getSenderFromContext();
    }

    /**
     * @dev Reverts if the caller is not allowed to call the function identified by a selector. Panics if the calldata
     * is less than 4 bytes long.
     */
    function _checkCanCall(address caller_, bytes calldata data_) internal override {
        bytes4 sig = bytes4(data_[0:4]);
        // @dev for context manager 87ef0b87 - setupContext, db99bddd - clearContext
        if (sig == bytes4(0x87ef0b87) || sig == bytes4(0xdb99bddd)) {
            caller_ = msg.sender;
        }

        AccessManagedStorage storage $ = _getAccessManagedStorage();
        (bool immediate, uint32 delay) = AuthorityUtils.canCallWithDelay(
            authority(),
            caller_,
            address(this),
            bytes4(data_[0:4])
        );
        if (!immediate) {
            if (delay > 0) {
                $._consumingSchedule = true;
                IAccessManager(authority()).consumeScheduledOp(caller_, data_);
                $._consumingSchedule = false;
            } else {
                revert AccessManagedUnauthorized(caller_);
            }
        }
    }
}

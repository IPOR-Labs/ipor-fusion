// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IporFeeAccount} from "./IporFeeAccount.sol";
import {PlasmaVaultGovernance} from "../../vaults/PlasmaVaultGovernance.sol";

struct InitializationData {
    address plasmaVault;
}

struct FeeManagerInitData {
    uint256 daoManagementFee;
    uint256 daoPerformanceFee;
    uint256 atomistManagementFee;
    uint256 atomistPerformanceFee;
    address initialAuthority;
    address plasmaVault;
    address feeRecipientAddress;
    address daoFeeRecipientAddress;
}

contract IporFusionFeeManager is AccessManaged {
    event HarvestManagementFee(address reciver, uint256 amount);
    event HarvestPerformanceFee(address reciver, uint256 amount);
    event PerformanceFeeUpdated(uint256 newPerformanceFee);
    event ManagementFeeUpdated(uint256 newManagementFee);

    error NotInitialized();
    error InvalidAddress();
    error AlreadyInitialized();
    error InvalidFeeRecipientAddress();

    address public immutable PERFORMANCE_FEE_ACCOUNT;
    address public immutable MANAGEMENT_FEE_ACCOUNT;
    /// @notice DAO_MANAGEMENT_FEE is in percentage with 2 decimals, example 10000 is 100%, 100 is 1%
    uint256 public immutable DAO_MANAGEMENT_FEE;
    /// @notice DAO_PERFORMANCE_FEE is in percentage with 2 decimals, example 10000 is 100%, 100 is 1%
    uint256 public immutable DAO_PERFORMANCE_FEE;

    address public immutable PLASMA_VAULT;
    address public feeRecipientAddress;
    address public daoFeeRecipientAddress;

    uint256 public performanceFee;
    uint256 public managementFee;

    /// @notice The flag indicating whether the contract is initialized, if it is, the value is greater than 0
    uint256 public initialized;

    constructor(FeeManagerInitData memory initData_) AccessManaged(initData_.initialAuthority) {
        PERFORMANCE_FEE_ACCOUNT = address(new IporFeeAccount(address(this)));
        MANAGEMENT_FEE_ACCOUNT = address(new IporFeeAccount(address(this)));

        DAO_MANAGEMENT_FEE = initData_.daoManagementFee;
        DAO_PERFORMANCE_FEE = initData_.daoPerformanceFee;

        performanceFee = initData_.atomistPerformanceFee + DAO_PERFORMANCE_FEE;
        managementFee = initData_.atomistManagementFee + DAO_MANAGEMENT_FEE;

        feeRecipientAddress = initData_.feeRecipientAddress;
        daoFeeRecipientAddress = initData_.daoFeeRecipientAddress;

        PLASMA_VAULT = initData_.plasmaVault;
    }

    function initialize() external {
        if(initialized != 0) {
            revert AlreadyInitialized();
        }

        initialized = 1;
        IporFeeAccount(PERFORMANCE_FEE_ACCOUNT).approveFeeManager(PLASMA_VAULT);
        IporFeeAccount(MANAGEMENT_FEE_ACCOUNT).approveFeeManager(PLASMA_VAULT);
    }


    function harvestManagementFee() public onlyInitialized {

        if(feeRecipientAddress == address(0) || daoFeeRecipientAddress == address(0)) {
            revert InvalidFeeRecipientAddress();
        }

        uint256 balance = IERC4626(PLASMA_VAULT).balanceOf(MANAGEMENT_FEE_ACCOUNT);

        if (balance == 0) {
            return;
        }

        uint256 decimals = IERC4626(PLASMA_VAULT).decimals();
        uint256 numberOfDecimals = 10 ** (decimals);

        uint256 percentToTransferToDao = (DAO_MANAGEMENT_FEE * numberOfDecimals) / managementFee;

        uint256 transferAmountToDao = Math.mulDiv(balance, percentToTransferToDao, numberOfDecimals);

        IERC4626(PLASMA_VAULT).transferFrom(MANAGEMENT_FEE_ACCOUNT, daoFeeRecipientAddress, transferAmountToDao);
        emit HarvestManagementFee(daoFeeRecipientAddress, transferAmountToDao);

        IERC4626(PLASMA_VAULT).transferFrom(MANAGEMENT_FEE_ACCOUNT, feeRecipientAddress, balance - transferAmountToDao);
        emit HarvestManagementFee(feeRecipientAddress, balance - transferAmountToDao);
    }

    function harvestPerformanceFee() public onlyInitialized {

        if(feeRecipientAddress == address(0) || daoFeeRecipientAddress == address(0)) {
            revert InvalidFeeRecipientAddress();
        }

        uint256 balance = IERC4626(PLASMA_VAULT).balanceOf(PERFORMANCE_FEE_ACCOUNT);

        if (balance == 0) {
            return;
        }

        uint256 decimals = IERC4626(PLASMA_VAULT).decimals();
        uint256 numberOfDecimals = 10 ** (decimals);

        uint256 percentToTransferToDao = (DAO_PERFORMANCE_FEE * numberOfDecimals) / performanceFee;

        uint256 transferAmountToDao = Math.mulDiv(balance, percentToTransferToDao, numberOfDecimals);

        IERC4626(PLASMA_VAULT).transfer(daoFeeRecipientAddress, transferAmountToDao);
        emit HarvestPerformanceFee(daoFeeRecipientAddress, transferAmountToDao);

        IERC4626(PLASMA_VAULT).transfer(feeRecipientAddress, balance - transferAmountToDao);
        emit HarvestPerformanceFee(feeRecipientAddress, balance - transferAmountToDao);
    }

    function updatePerformanceFee(uint256 performanceFee_) external restricted {
        harvestPerformanceFee();

        uint256 newPerformanceFee = performanceFee_ + DAO_PERFORMANCE_FEE;

        PlasmaVaultGovernance(PLASMA_VAULT).configurePerformanceFee(PERFORMANCE_FEE_ACCOUNT, newPerformanceFee);
        performanceFee = newPerformanceFee;

        emit PerformanceFeeUpdated(newPerformanceFee);
    }

    function updateManagementFee(uint256 managementFee_) external restricted {
        harvestManagementFee();

        uint256 newManagementFee = managementFee_ + DAO_MANAGEMENT_FEE;

        PlasmaVaultGovernance(PLASMA_VAULT).configureManagementFee(MANAGEMENT_FEE_ACCOUNT, newManagementFee);
        managementFee = newManagementFee;

        emit ManagementFeeUpdated(newManagementFee);
    }

    // todo add role atomist role to function
    function setFeeRecipientAddress(address harvestAddress_) external restricted {
        if (harvestAddress_ == address(0)) {
            revert InvalidAddress();
        }

        feeRecipientAddress = harvestAddress_;
    }

    // todo add dao role to function
    function setDaoFeeRecipientAddress(address daoHarvestAddress_) external restricted {
        if (daoHarvestAddress_ == address(0)) {
            revert InvalidAddress();
        }

        daoFeeRecipientAddress = daoHarvestAddress_;
    }

    modifier onlyInitialized() {
        if (initialized == 0) {
            revert NotInitialized();
        }
        _;
    }
}

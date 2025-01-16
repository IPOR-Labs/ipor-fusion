// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {FeeManager, FeeManagerInitData} from "./FeeManager.sol";

/// @notice Struct containing fee configuration for a single recipient
/// @dev All fee values are stored with 2 decimal precision
/// @param recipient The address that will receive the fees
/// @param feeValue Fee percentage allocated to this recipient (10000 = 100%, 100 = 1%)
struct RecipientFee {
    address recipient;
    uint256 feeValue;
}

/// @notice Configuration parameters for initializing a new fee management system
/// @dev Used to set up initial fee structure and recipients for a plasma vault
struct FeeConfig {
    /// @notice Address of the factory contract deploying the fee manager
    address feeFactory;
    /// @notice Base management fee allocated to the IPOR DAO
    /// @dev Percentage with 2 decimal precision (10000 = 100%, 100 = 1%)
    uint256 iporDaoManagementFee;
    /// @notice Base performance fee allocated to the IPOR DAO
    /// @dev Percentage with 2 decimal precision (10000 = 100%, 100 = 1%)
    uint256 iporDaoPerformanceFee;
    /// @notice Address that receives the IPOR DAO's portion of fees
    /// @dev Must be non-zero address
    address iporDaoFeeRecipientAddress;
    /// @notice List of additional management fee recipients and their allocations
    /// @dev Total of all management fees (including DAO) must not exceed 100%
    RecipientFee[] recipientManagementFees;
    /// @notice List of additional performance fee recipients and their allocations
    /// @dev Total of all performance fees (including DAO) must not exceed 100%
    RecipientFee[] recipientPerformanceFees;
}

/// @notice Data structure containing deployed fee manager details
/// @dev Returned after successful deployment of a new fee manager
struct FeeManagerData {
    /// @notice Address of the deployed fee manager contract
    address feeManager;
    /// @notice Address of the associated plasma vault
    address plasmaVault;
    /// @notice Account that collects performance fees before distribution
    address performanceFeeAccount;
    /// @notice Account that collects management fees before distribution
    address managementFeeAccount;
    /// @notice Total management fee percentage (sum of all recipients including DAO)
    /// @dev Stored with 2 decimal precision (10000 = 100%, 100 = 1%)
    uint256 managementFee;
    /// @notice Total performance fee percentage (sum of all recipients including DAO)
    /// @dev Stored with 2 decimal precision (10000 = 100%, 100 = 1%)
    uint256 performanceFee;
}

/// @title FeeManagerFactory
/// @notice Factory contract for deploying and initializing FeeManager instances
/// @dev Creates standardized fee management systems for plasma vaults
contract FeeManagerFactory {
    /// @notice Deploys a new FeeManager contract with the specified configuration
    /// @dev Creates and initializes a new FeeManager with associated fee accounts
    /// @param initData_ Initialization parameters for the fee manager
    /// @return Data structure containing addresses and fee information of the deployed system
    /// @custom:security Validates fee recipient addresses and fee percentages during deployment
    function deployFeeManager(FeeManagerInitData memory initData_) external returns (FeeManagerData memory) {
        FeeManager feeManager = new FeeManager(initData_);

        return
            FeeManagerData({
                feeManager: address(feeManager),
                plasmaVault: feeManager.PLASMA_VAULT(),
                performanceFeeAccount: feeManager.PERFORMANCE_FEE_ACCOUNT(),
                managementFeeAccount: feeManager.MANAGEMENT_FEE_ACCOUNT(),
                managementFee: feeManager.getTotalManagementFee(),
                performanceFee: feeManager.getTotalPerformanceFee()
            });
    }
}

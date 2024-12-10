// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {FeeManager, FeeManagerInitData} from "./FeeManager.sol";
import {FeeManagerStorage} from "./FeeManagerStorageLib.sol";

/// @notice Struct containing data related to the fee manager
/// @param feeManager Address of the fee manager
/// @param plasmaVault Address of the plasma vault
/// @param performanceFeeAccount Address of the performance fee account
/// @param managementFeeAccount Address of the management fee account
/// @param managementFee Management fee percentage (in percentage with 2 decimals, example 10000 is 100%, 100 is 1%)
/// @param performanceFee Performance fee percentage (in percentage with 2 decimals, example 10000 is 100%, 100 is 1%)
struct FeeManagerData {
    address feeManager;
    address plasmaVault;
    address performanceFeeAccount;
    address managementFeeAccount;
    uint256 managementFee;
    uint256 performanceFee;
}

/// @title FeeManagerFactory
/// @notice Factory contract for deploying FeeManager instances
contract FeeManagerFactory {
    /// @notice Deploys a new FeeManager contract
    /// @param initData Initialization data for the fee manager
    /// @return FeeManagerData containing addresses and fee information of the deployed fee manager
    function deployFeeManager(FeeManagerInitData memory initData) external returns (FeeManagerData memory) {
        FeeManager feeManager = new FeeManager(initData);
        FeeManagerStorage memory feeConfig = feeManager.getFeeConfig();

        return
            FeeManagerData({
                feeManager: address(feeManager),
                plasmaVault: feeManager.PLASMA_VAULT(),
                performanceFeeAccount: feeManager.PERFORMANCE_FEE_ACCOUNT(),
                managementFeeAccount: feeManager.MANAGEMENT_FEE_ACCOUNT(),
                managementFee: feeConfig.plasmaVaultManagementFee,
                performanceFee: feeConfig.plasmaVaultPerformanceFee
            });
    }
}

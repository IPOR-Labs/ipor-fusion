// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IporFusionFeeManager, FeeManagerInitData} from "./IporFusionFeeManager.sol";

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

/// @title IporFeeFactory
/// @notice Factory contract for deploying IporFusionFeeManager instances
contract IporFeeFactory {
    /// @notice Deploys a new IporFusionFeeManager contract
    /// @param initData Initialization data for the fee manager
    /// @return FeeManagerData containing addresses and fee information of the deployed fee manager
    function deployFeeManager(FeeManagerInitData memory initData) external returns (FeeManagerData memory) {
        IporFusionFeeManager feeManager = new IporFusionFeeManager(initData);

        return
            FeeManagerData({
                feeManager: address(feeManager),
                plasmaVault: feeManager.PLASMA_VAULT(),
                performanceFeeAccount: feeManager.PERFORMANCE_FEE_ACCOUNT(),
                managementFeeAccount: feeManager.MANAGEMENT_FEE_ACCOUNT(),
                managementFee: feeManager.managementFee(),
                performanceFee: feeManager.performanceFee()
            });
    }
}

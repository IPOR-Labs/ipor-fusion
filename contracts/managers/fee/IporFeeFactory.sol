// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IporFusionFeeManager, FeeManagerInitData} from "./IporFusionFeeManager.sol";

struct FeeManagerData {
    address feeManager;
    address plasmaVault;
    address performanceFeeAccount;
    address managementFeeAccount;
    uint256 managementFee;
    uint256 performanceFee;
}

contract IporFeeFactory {
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

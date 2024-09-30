// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract IporFeeAccount {
    using SafeERC20 for IERC20;

    error OnlyFeeManagerCanApprove();

    address public immutable FEE_MANAGER;

    constructor(address feeManager_) {
        FEE_MANAGER = feeManager_;
    }

    function approveFeeManager(address plasmaVault) external {
        if (msg.sender != FEE_MANAGER) {
            revert OnlyFeeManagerCanApprove();
        }

        IERC20(plasmaVault).forceApprove(FEE_MANAGER, type(uint256).max);
    }
}

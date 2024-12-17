// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title FeeAccount
/// @notice Account contract that holds collected fees before distribution
/// @dev Each FeeAccount is dedicated to either management or performance fees
/// @dev Uses SafeERC20 for secure token operations
contract FeeAccount {
    using SafeERC20 for IERC20;

    /// @notice Error thrown when approval is attempted by non-fee manager address
    /// @dev Ensures only the designated fee manager can set token approvals
    error OnlyFeeManagerCanApprove();

    /// @notice The address of the FeeManager contract that controls this account
    /// @dev Set during construction and cannot be changed
    /// @dev This address has exclusive rights to manage token approvals
    address public immutable FEE_MANAGER;

    /// @notice Creates a new FeeAccount instance
    /// @dev Sets the immutable fee manager address
    /// @param feeManager_ Address of the FeeManager contract that will control this account
    /// @custom:security The fee manager address cannot be changed after deployment
    constructor(address feeManager_) {
        FEE_MANAGER = feeManager_;
    }

    /// @notice Approves the fee manager to spend the maximum amount of vault tokens
    /// @dev Uses force approve to handle tokens that require approval to be set to 0 first
    /// @param plasmaVault Address of the ERC20 vault token to approve
    /// @custom:access Only callable by the FEE_MANAGER address
    /// @custom:security Uses SafeERC20 for safe token operations
    function approveMaxForFeeManager(address plasmaVault) external {
        if (msg.sender != FEE_MANAGER) {
            revert OnlyFeeManagerCanApprove();
        }

        IERC20(plasmaVault).forceApprove(FEE_MANAGER, type(uint256).max);
    }
}

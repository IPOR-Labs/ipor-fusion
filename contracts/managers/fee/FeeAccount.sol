// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title FeeAccount
/// @notice Contract responsible for managing fee approvals for the Ipor protocol
contract FeeAccount {
    using SafeERC20 for IERC20;

    /// @notice Error thrown when a non-fee manager tries to approve
    error OnlyFeeManagerCanApprove();

    /// @notice Address of the Fee Manager contract
    address public immutable FEE_MANAGER;

    constructor(address feeManager_) {
        FEE_MANAGER = feeManager_;
    }

    /// @notice Max approves the fee manager to spend tokens on behalf of the contract
    /// @param plasmaVault Address of the plasma vault token
    function approveMaxForFeeManager(address plasmaVault) external {
        if (msg.sender != FEE_MANAGER) {
            revert OnlyFeeManagerCanApprove();
        }

        IERC20(plasmaVault).forceApprove(FEE_MANAGER, type(uint256).max);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {console2} from "forge-std/console2.sol";

/// @title MockTokenVault
/// @notice Mock contract for testing async actions with deposit and withdraw functionality
/// @dev Simple vault that accepts ERC20 deposits and allows withdrawals
contract MockTokenVault {
    using SafeERC20 for IERC20;

    /// @notice Emitted when tokens are deposited
    /// @param user Address that deposited tokens
    /// @param token Address of the token deposited
    /// @param amount Amount of tokens deposited
    event Deposit(address indexed user, address indexed token, uint256 amount);

    /// @notice Emitted when tokens are withdrawn
    /// @param user Address that withdrew tokens
    /// @param token Address of the token withdrawn
    /// @param amount Amount of tokens withdrawn
    event Withdraw(address indexed user, address indexed token, uint256 amount);

    /// @notice Thrown when withdrawal amount exceeds balance
    /// @custom:error InsufficientBalance
    error InsufficientBalance(uint256 requested, uint256 available);

    /// @notice Deposits ERC20 tokens into the vault
    /// @param token_ Address of the ERC20 token to deposit
    /// @param amount_ Amount of tokens to deposit
    /// @dev Transfers tokens from the caller to this contract
    function deposit(address token_, uint256 amount_) external {
        IERC20(token_).safeTransferFrom(msg.sender, address(this), amount_);
        emit Deposit(msg.sender, token_, amount_);
    }

    /// @notice Withdraws ERC20 tokens from the vault
    /// @param token_ Address of the ERC20 token to withdraw
    /// @param amount_ Amount of tokens to withdraw
    /// @dev Transfers tokens from this contract to the caller
    function withdraw(address token_, uint256 amount_) external {
        uint256 balance = IERC20(token_).balanceOf(address(this));
        if (amount_ > balance) {
            revert InsufficientBalance(amount_, balance);
        }
        console2.log("withdrawing tokens from mock token vault", token_, amount_);
        IERC20(token_).safeTransfer(msg.sender, amount_);
        emit Withdraw(msg.sender, token_, amount_);
    }

    /// @notice Returns the balance of a specific token in the vault
    /// @param token_ Address of the ERC20 token
    /// @return Balance of the token in the vault
    function balanceOf(address token_) external view returns (uint256) {
        return IERC20(token_).balanceOf(address(this));
    }
}


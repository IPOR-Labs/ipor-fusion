// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

/// @title MockEnsoTarget
/// @notice Mock contract that serves as a target for Enso operations
/// @dev This contract simulates various DeFi operations like swaps, liquidity provision, etc.
contract MockEnsoTarget {
    event TokensSwapped(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);
    event OperationExecuted(address caller, bytes data);

    /// @notice Mock swap function
    /// @param tokenIn_ Input token address
    /// @param tokenOut_ Output token address
    /// @param amountIn_ Amount of input tokens
    /// @param amountOut_ Amount of output tokens
    function swap(address tokenIn_, address tokenOut_, uint256 amountIn_, uint256 amountOut_) external payable {
        // Transfer tokens in
        if (amountIn_ > 0) {
            IERC20(tokenIn_).transferFrom(msg.sender, address(this), amountIn_);
        }

        // Transfer tokens out
        if (amountOut_ > 0) {
            IERC20(tokenOut_).transfer(msg.sender, amountOut_);
        }

        emit TokensSwapped(tokenIn_, tokenOut_, amountIn_, amountOut_);
    }

    /// @notice Mock liquidity add function
    /// @param token_ Token address
    /// @param amount_ Amount to add
    function addLiquidity(address token_, uint256 amount_) external {
        IERC20(token_).transferFrom(msg.sender, address(this), amount_);
        emit OperationExecuted(msg.sender, abi.encodeWithSignature("addLiquidity(address,uint256)", token_, amount_));
    }

    /// @notice Mock liquidity remove function
    /// @param token_ Token address
    /// @param amount_ Amount to remove
    function removeLiquidity(address token_, uint256 amount_) external {
        IERC20(token_).transfer(msg.sender, amount_);
        emit OperationExecuted(
            msg.sender,
            abi.encodeWithSignature("removeLiquidity(address,uint256)", token_, amount_)
        );
    }

    /// @notice Allows contract to receive ETH
    receive() external payable {}

    /// @notice Fund the contract with tokens for testing
    /// @param token_ Token address
    /// @param amount_ Amount to fund
    function fund(address token_, uint256 amount_) external {
        IERC20(token_).transferFrom(msg.sender, address(this), amount_);
    }
}

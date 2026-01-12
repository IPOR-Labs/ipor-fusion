// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title SwapExecutorData
/// @notice Contains all data required for executing token swaps across DEXes
struct SwapExecutorData {
    /// @notice The input token address to be swapped
    address tokenIn;
    /// @notice The output token address to receive
    address tokenOut;
    /// @notice Array of DEX contract addresses to call
    address[] dexs;
    /// @notice Array of encoded function call data for each DEX
    bytes[] dexsData;
}

/// @title SwapExecutor
/// @notice Executes token swaps across multiple DEX protocols
/// @dev Uses ReentrancyGuard to prevent reentrancy attacks during external DEX calls
/// @author IPOR Labs
contract SwapExecutor is ReentrancyGuard {
    using Address for address;
    using SafeERC20 for IERC20;

    /// @notice Error thrown when dexs and dexsData arrays have different lengths
    error ArrayLengthMismatch();

    /**
     * @notice Executes a series of token swaps across multiple decentralized exchanges (DEXes).
     *
     * @dev This function iterates over a list of DEXes and executes a swap on each using provided swap data.
     * After the swaps, the function checks the token balances of both the input token (`tokenIn`) and the output token (`tokenOut`)
     * in the contract. Any remaining tokens of either type are transferred back to the caller.
     * Protected against reentrancy via nonReentrant modifier.
     *
     * @param data_ The `SwapExecutorData` struct which contains all the necessary data for executing swaps.
     * It includes:
     * - `dexs`: An array of DEX contract addresses.
     * - `dexsData`: An array of encoded function call data corresponding to each DEX.
     * - `tokenIn`: The address of the input token.
     * - `tokenOut`: The address of the output token.
     * @custom:revert ArrayLengthMismatch When dexs and dexsData arrays have different lengths
     * @custom:security External calls to DEX addresses are protected by nonReentrant modifier
     * @custom:security Caller must transfer tokens to this contract before calling
     * @custom:security Caller is responsible for providing valid and trusted DEX addresses
     */
    function execute(SwapExecutorData calldata data_) external nonReentrant {
        uint256 len = data_.dexs.length;
        if (len != data_.dexsData.length) {
            revert ArrayLengthMismatch();
        }
        for (uint256 i; i < len; ) {
            data_.dexs[i].functionCall(data_.dexsData[i]);
            unchecked {
                ++i;
            }
        }

        // Handle tokenIn == tokenOut case to avoid double transfer revert
        if (data_.tokenIn == data_.tokenOut) {
            uint256 balance = IERC20(data_.tokenIn).balanceOf(address(this));
            if (balance > 0) {
                IERC20(data_.tokenIn).safeTransfer(msg.sender, balance);
            }
        } else {
            uint256 balanceTokenIn = IERC20(data_.tokenIn).balanceOf(address(this));
            uint256 balanceTokenOut = IERC20(data_.tokenOut).balanceOf(address(this));

            if (balanceTokenIn > 0) {
                IERC20(data_.tokenIn).safeTransfer(msg.sender, balanceTokenIn);
            }

            if (balanceTokenOut > 0) {
                IERC20(data_.tokenOut).safeTransfer(msg.sender, balanceTokenOut);
            }
        }
    }
}

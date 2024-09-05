// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

struct SwapExecutorData {
    address tokenIn;
    address tokenOut;
    address[] dexs;
    bytes[] dexsData;
}

contract SwapExecutor {
    using Address for address;

    /**
     * @notice Executes a series of token swaps across multiple decentralized exchanges (DEXes).
     *
     * @dev This function iterates over a list of DEXes and executes a swap on each using provided swap data.
     * After the swaps, the function checks the token balances of both the input token (`tokenIn`) and the output token (`tokenOut`)
     * in the contract. Any remaining tokens of either type are transferred back to the caller.
     *
     * @param data_ The `SwapExecutorData` struct which contains all the necessary data for executing swaps.
     * It includes:
     * - `dexs`: An array of DEX contract addresses.
     * - `dexData`: An array of encoded function call data corresponding to each DEX.
     * - `tokenIn`: The address of the input token.
     * - `tokenOut`: The address of the output token.
     */
    function execute(SwapExecutorData memory data_) externa{
        uint256 len = data.dexs.length;
        for (uint256 i; i < len; ++i) {
            data_.dexs[i].functionCall(data_.dexsData[i]);
        }

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

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title IWETH9 Interface
/// @notice Interface for Wrapped Ether (WETH) token with deposit and withdraw functionality
interface IWETH9 {
    /// @notice Deposit ETH to receive WETH
    function deposit() external payable;

    /// @notice Withdraw ETH from WETH
    /// @param amount Amount of WETH to withdraw
    function withdraw(uint256 amount) external;
}

/// @title SwapExecutorEthData
/// @notice Data structure containing all necessary information for executing a swap operation
/// @param tokenIn Address of the input token
/// @param tokenOut Address of the output token
/// @param targets Array of target addresses for the swap operations
/// @param callDatas Array of encoded function calls for each target
/// @param ethAmounts Array of ETH amounts to be sent with each call
/// @param tokensDustToCheck Array of token addresses to check for dust balances
struct SwapExecutorEthData {
    address tokenIn;
    address tokenOut;
    address[] targets;
    bytes[] callDatas;
    uint256[] ethAmounts;
    address[] tokensDustToCheck;
}

/// @title SwapExecutorEth
/// @notice Contract responsible for executing token swaps and handling ETH transfers
/// @dev This contract manages the execution of swap operations, including ETH transfers and dust balance checks
contract SwapExecutorEth {
    using Address for address;
    using SafeERC20 for IERC20;

    /// @notice Error thrown when an invalid WETH address is provided
    error SwapExecutorEthInvalidWethAddress();

    /// @notice Error thrown when array lengths in SwapExecutorEthData do not match
    error SwapExecutorEthInvalidArrayLength();

    /// @notice Event emitted when a swap execution is completed
    /// @param sender Address that initiated the swap
    /// @param tokenIn Address of the input token
    /// @param tokenOut Address of the output token
    event SwapExecutorEthExecuted(address indexed sender, address indexed tokenIn, address indexed tokenOut);

    /// @notice Address of the WETH contract
    address public immutable W_ETH;

    /// @notice Constructs the SwapExecutorEth contract
    /// @param wEth_ Address of the WETH contract
    /// @dev Reverts if wEth_ is the zero address
    constructor(address wEth_) {
        if (wEth_ == address(0)) {
            revert SwapExecutorEthInvalidWethAddress();
        }
        W_ETH = wEth_;
    }

    /// @notice Executes a series of swap operations
    /// @param data_ SwapExecutorEthData containing all necessary information for the swap
    /// @dev This function:
    ///      - Validates array lengths
    ///      - Executes calls to target contracts
    ///      - Handles ETH transfers
    ///      - Transfers remaining tokens to the sender
    ///      - Converts remaining ETH to WETH and transfers it
    ///      - Checks and transfers any dust balances
    function execute(SwapExecutorEthData memory data_) external {
        uint256 len = data_.targets.length;

        if (len != data_.callDatas.length || len != data_.ethAmounts.length) {
            revert SwapExecutorEthInvalidArrayLength();
        }

        for (uint256 i; i < len; ++i) {
            if (data_.ethAmounts[i] > 0) {
                Address.functionCallWithValue(data_.targets[i], data_.callDatas[i], data_.ethAmounts[i]);
            } else {
                Address.functionCall(data_.targets[i], data_.callDatas[i]);
            }
        }

        uint256 balanceTokenIn = IERC20(data_.tokenIn).balanceOf(address(this));
        uint256 balanceTokenOut = IERC20(data_.tokenOut).balanceOf(address(this));

        if (balanceTokenIn > 0) {
            IERC20(data_.tokenIn).safeTransfer(msg.sender, balanceTokenIn);
        }

        if (balanceTokenOut > 0) {
            IERC20(data_.tokenOut).safeTransfer(msg.sender, balanceTokenOut);
        }

        uint256 balanceEth = address(this).balance;

        if (balanceEth > 0) {
            IWETH9(W_ETH).deposit{value: balanceEth}();
            IERC20(W_ETH).safeTransfer(msg.sender, balanceEth);
        }

        uint256 lenDustToCheck = data_.tokensDustToCheck.length;
        uint256 dustBalance;
        for (uint256 i; i < lenDustToCheck; ++i) {
            dustBalance = IERC20(data_.tokensDustToCheck[i]).balanceOf(address(this));
            if (dustBalance > 0) {
                IERC20(data_.tokensDustToCheck[i]).safeTransfer(msg.sender, dustBalance);
            }
        }

        emit SwapExecutorEthExecuted(msg.sender, data_.tokenIn, data_.tokenOut);
    }

    /// @notice Allows the contract to receive ETH
    receive() external payable {}
}

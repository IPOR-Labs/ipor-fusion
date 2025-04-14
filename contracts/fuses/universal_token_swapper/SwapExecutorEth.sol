// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IWETH9 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

struct SwapExecutorEthData {
    address tokenIn;
    address tokenOut;
    address[] targets;
    bytes[] callData;
    uint256[] ethAmounts;
    address[] dustToCheck;
}

contract SwapExecutorEth {
    using Address for address;
    using SafeERC20 for IERC20;

    address public immutable W_ETH;

    constructor(address wEth_) {
        W_ETH = wEth_;
    }

    function execute(SwapExecutorEthData memory data_) external {
        uint256 len = data_.targets.length;
        for (uint256 i; i < len; ++i) {
            if (data_.ethAmounts[i] > 0) {
                Address.functionCallWithValue(data_.targets[i], data_.callData[i], data_.ethAmounts[i]);
            } else {
                Address.functionCall(data_.targets[i], data_.callData[i]);
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

        uint256 lenDustToCheck = data_.dustToCheck.length;
        uint256 dustBalance;
        for (uint256 i; i < lenDustToCheck; ++i) {
            dustBalance = IERC20(data_.dustToCheck[i]).balanceOf(address(this));
            if (dustBalance > 0) {
                IERC20(data_.dustToCheck[i]).safeTransfer(msg.sender, dustBalance);
            }
        }
    }

    receive() external payable {}
}

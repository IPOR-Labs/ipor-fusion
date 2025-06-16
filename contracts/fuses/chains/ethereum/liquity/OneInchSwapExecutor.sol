// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SwapExecutor} from "../../../universal_token_swapper/SwapExecutor.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract OneInchSwapExecutor is SwapExecutor {
    using SafeERC20 for ERC20;

    function approveTarget(address dex, address tokenOut, uint256 amount) external {
        // Approve the DEX to spend the input token
        ERC20(tokenOut).forceApprove(dex, amount);
    }
}

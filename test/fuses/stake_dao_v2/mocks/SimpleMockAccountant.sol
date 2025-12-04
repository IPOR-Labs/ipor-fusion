// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract SimpleMockAccountant {
    using SafeERC20 for IERC20;

    address public immutable REWARD_TOKEN;
    uint256 public immutable REWARD_AMOUNT;

    constructor(address rewardToken, uint256 rewardAmount) {
        REWARD_TOKEN = rewardToken;
        REWARD_AMOUNT = rewardAmount;
    }

    function claim(address[] calldata, bytes[] calldata, address receiver) external {
        IERC20(REWARD_TOKEN).safeTransfer(receiver, REWARD_AMOUNT);
    }
}

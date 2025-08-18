// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRewardVault} from "../../../../contracts/fuses/stake_dao_v2/ext/IRewardVault.sol";
import {IAccountant} from "../../../../contracts/fuses/stake_dao_v2/ext/IAccountant.sol";

contract MockRewardVault {
    using SafeERC20 for IERC20;

    address public immutable REWARD_TOKEN_1;
    address public immutable REWARD_TOKEN_2;
    uint256 public immutable REWARD_AMOUNT_1;
    uint256 public immutable REWARD_AMOUNT_2;
    address public immutable GAUGE;
    address public immutable ACCOUNTANT_ADDRESS;

    constructor(address rewardToken1, address rewardToken2, uint256 rewardAmount1, uint256 rewardAmount2) {
        REWARD_TOKEN_1 = rewardToken1;
        REWARD_TOKEN_2 = rewardToken2;
        REWARD_AMOUNT_1 = rewardAmount1;
        REWARD_AMOUNT_2 = rewardAmount2;
        GAUGE = address(0x1234567890123456789012345678901234567890); // Mock gauge address
        ACCOUNTANT_ADDRESS = address(0x2345678901234567890123456789012345678901); // Mock accountant address
    }

    /// @notice Claims rewards for multiple tokens in a single transaction
    /// @param tokens Array of reward token addresses to claim
    /// @param receiver Address to receive the claimed rewards
    /// @return amounts Array of amounts claimed for each token
    function claim(address[] calldata tokens, address receiver) external returns (uint256[] memory amounts) {
        amounts = new uint256[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == REWARD_TOKEN_1) {
                IERC20(REWARD_TOKEN_1).safeTransfer(receiver, REWARD_AMOUNT_1);
                amounts[i] = REWARD_AMOUNT_1;
            } else if (tokens[i] == REWARD_TOKEN_2) {
                IERC20(REWARD_TOKEN_2).safeTransfer(receiver, REWARD_AMOUNT_2);
                amounts[i] = REWARD_AMOUNT_2;
            }
        }

        return amounts;
    }

    /// @notice Returns the gauge address
    function gauge() external view returns (address) {
        return GAUGE;
    }

    /// @notice Returns the accountant address
    function ACCOUNTANT() external view returns (IAccountant) {
        return IAccountant(ACCOUNTANT_ADDRESS);
    }
}

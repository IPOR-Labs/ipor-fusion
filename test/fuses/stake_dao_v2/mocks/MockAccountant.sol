// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockAccountant {
    using Address for address;
    using SafeERC20 for IERC20;

    /// @notice The reward token distributed by this accountant (e.g., CRV, BAL).
    address public immutable REWARD_TOKEN;

    mapping(address gauge => mapping(address account => uint256 amount)) public mockedRewards;

    constructor(address rewardToken) {
        REWARD_TOKEN = rewardToken;
    }

    function claim(address[] calldata gauges_, bytes[] calldata harvestData_, address receiver_) external {
        address account = msg.sender;

        uint256 totalAmount;

        for (uint256 i; i < gauges_.length; i++) {
            totalAmount += mockedRewards[gauges_[i]][account];
        }

        IERC20(REWARD_TOKEN).safeTransfer(receiver_, totalAmount);
    }

    function setMockedRewards(address gauge, address account, uint256 amount) public {
        mockedRewards[gauge][account] = amount;
    }

    function getMockedRewards(address gauge, address account) public view returns (uint256) {
        return mockedRewards[gauge][account];
    }
}

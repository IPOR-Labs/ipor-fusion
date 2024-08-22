// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IFarmingPool is IERC20 {
    function farmed(address account) external view returns (uint256);

    function deposit(uint256 amount) external;

    function withdraw(uint256 amount) external;

    function claim() external;

    function exit() external;

    function stakingToken() external view returns (address);

    function rewardsToken() external view returns (address);
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

interface IFluidLendingStakingRewards {
    function nextPeriodFinish() external view returns (uint256);

    function nextRewardRate() external view returns (uint256);

    function periodFinish() external view returns (uint256);

    function rewardRate() external view returns (uint256);

    function rewardsDuration() external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    /// @notice gets last time where rewards accrue, also considering already queued next rewards
    function lastTimeRewardApplicable() external view returns (uint256);

    /// @notice gets reward amount per token, also considering automatic transition to queued next rewards
    function rewardPerToken() external view returns (uint256);

    /// @notice gets earned reward amount for an `account`, also considering automatic transition to queued next rewards
    function earned(address account) external view returns (uint256);

    /// @notice gets reward amount for current duration, also considering automatic transition to queued next rewards
    function getRewardForDuration() external view returns (uint256);

    function rewardsToken() external view returns (address);

    function stakingToken() external view returns (address);

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stakeWithPermit(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;

    function stake(uint256 amount) external;

    function withdraw(uint256 amount) external;

    function getReward() external;

    function exit() external;

    /// @notice updates rewards until current block.timestamp or `periodFinish`. Transitions to next rewards
    /// if previous rewards ended and next ones were queued.
    function updateRewards() external;
}

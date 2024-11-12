// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

interface MultiRewardDistributor {
    struct MarketConfig {
        // The owner/admin of the emission config
        address owner;
        // The emission token
        address emissionToken;
        // Scheduled to end at this time
        uint256 endTime;
        // Supplier global state
        uint224 supplyGlobalIndex;
        uint32 supplyGlobalTimestamp;
        // Borrower global state
        uint224 borrowGlobalIndex;
        uint32 borrowGlobalTimestamp;
        uint256 supplyEmissionsPerSec;
        uint256 borrowEmissionsPerSec;
    }

    struct RewardInfo {
        address emissionToken;
        uint256 totalAmount;
        uint256 supplySide;
        uint256 borrowSide;
    }

    struct RewardWithMToken {
        address mToken;
        RewardInfo[] rewards;
    }

    /// @notice Get the reward token address for a given index
    /// @param index The index of the reward token
    /// @return The address of the reward token
    function rewardTokens(uint8 index) external view returns (address);

    /// @notice Claims rewards for a holder across specified mTokens
    /// @param holder The address to claim rewards for
    /// @param mTokens Array of mToken addresses to claim from
    function claimRewards(address holder, address[] memory mTokens) external;

    /// @notice Get outstanding rewards for a user
    /// @param user The user address to check rewards for
    /// @param rewardType The type of reward (0 or 1)
    /// @return The amount of outstanding rewards
    function getOutstandingRewardsForUser(address user, uint8 rewardType) external view returns (uint256);

    /// @notice Get all market configs for a given mToken
    /// @param mToken The mToken to get configs for
    /// @return Array of market configs
    function getAllMarketConfigs(address mToken) external view returns (MarketConfig[] memory);

    /// @notice Get outstanding rewards for a user across all markets
    /// @param user The user address to check rewards for
    /// @return Array of rewards with mToken info
    function getOutstandingRewardsForUser(address user) external view returns (RewardWithMToken[] memory);

    /// @notice Get outstanding rewards for a user in a specific market
    /// @param mToken The mToken market to check
    /// @param user The user address to check rewards for
    /// @return Array of reward info
    function getOutstandingRewardsForUser(address mToken, address user) external view returns (RewardInfo[] memory);
}

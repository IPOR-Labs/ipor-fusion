// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {FuseAction} from "../interfaces/IPlasmaVault.sol";

/// @notice Vesting data struct
/// @custom:storage-location erc7201:io.ipor.managers.rewards.VestingData
struct VestingData {
    /// @notice vestingTime The time when the vesting is pending
    uint32 vestingTime;
    /// @notice updateBalanceTimestamp The timestamp of the last balance update
    uint32 updateBalanceTimestamp;
    /// @notice transferredTokens The number of tokens that have been transferred from RewardsClaimManager to the Plasma Vault
    uint128 transferredTokens;
    /// @notice lastUpdateBalance The balance of the last update
    uint128 lastUpdateBalance;
}

/// @title Rewards Claim Manager interface
interface IRewardsClaimManager {
    /// @notice Retrieves the balance of linear vested underlying tokens owned by RewardsClaimManager.sol contract
    /// @return balance The balance of the vesting data in uint256.
    /// @dev This method calculates the current balance based on the vesting schedule.
    /// If the `updateBalanceTimestamp` is zero, it returns zero. Otherwise, it calculates
    /// the ratio of the elapsed time to the total vesting time to determine the proportion
    /// of the balance that is currently available. The balance is adjusted by the number
    /// of tokens that have already been transferred. Thr result is in underlying token decimals.
    function balanceOf() external view returns (uint256);

    /// @notice Checks if the specified reward fuse is supported.
    /// @param fuse_ The address of the fuse to be checked.
    /// @return supported A boolean value indicating whether the reward fuse is supported.
    /// @dev This method checks the internal configuration to determine if the provided fuse address
    /// is supported for reward management.
    function isRewardFuseSupported(address fuse_) external view returns (bool);

    /// @notice Retrieves the vesting data.
    /// @return vestingData A struct containing the vesting data.
    /// @dev This method returns the current state of the vesting data, including details such as
    /// the last update balance, the transferred tokens, and the timestamp of the last update.
    function getVestingData() external view returns (VestingData memory);

    /// @notice Transfers a specified amount of an asset to a given address.
    /// @param asset_ The address of the asset to be transferred.
    /// @param to_ The address of the recipient.
    /// @param amount_ The amount of the asset to be transferred, represented in the asset's decimals.
    /// @dev This method facilitates the transfer of a specified amount of the given asset from the contract to the recipient's address.
    function transfer(address asset_, address to_, uint256 amount_) external;

    /// @notice Adds multiple reward fuses.
    /// @param fuses_ An array of addresses representing the fuses to be added.
    /// @dev This method adds the provided list of fuse addresses to the contract's configuration.
    /// It allows the inclusion of multiple fuses in a single transaction for reward management purposes.
    function addRewardFuses(address[] calldata fuses_) external;

    /// @notice Removes a specified reward fuse.
    /// @param fuses_ The addresses of the fuse to be removed.
    /// @dev This method removes the provided fuse address from the contract's configuration.
    /// It is used to manage and update the list of supported reward fuses.
    function removeRewardFuses(address[] calldata fuses_) external;

    /// @notice Claims rewards based on the provided fuse actions.
    /// @param calls_ An array of FuseAction structs representing the actions for claiming rewards.
    /// @dev This method processes the provided fuse actions to claim the corresponding rewards.
    /// Each FuseAction in the array is executed to facilitate the reward claim process.
    function claimRewards(FuseAction[] calldata calls_) external;

    /// @notice Sets up the vesting schedule with a specified delay for token release.
    /// @param releaseTokensDelay_ The delay in seconds before the tokens are released.
    /// @dev This method configures the vesting schedule by setting the delay time for token release.
    /// The delay defines the period that must pass before the tokens can be released to the beneficiary.
    // @dev setting up this to zero will stopped vesting and freeze underling token on the contract
    function setupVestingTime(uint256 releaseTokensDelay_) external;

    /// @notice Updates the balance based on the current vesting schedule and transferred tokens.
    /// @dev This method recalculates the balance considering the elapsed time, vesting schedule,
    /// and the number of tokens that have already been transferred. It updates the internal
    /// state to reflect the latest balance.
    function updateBalance() external;

    /// @notice Transfers vested underlying tokens to the Plasma Vault.
    /// @dev This method transfers the underlying tokens that have vested according to the vesting schedule
    /// to the designated Plasma Vault. It ensures that only the vested portion of the underlying tokens
    /// is transferred.
    function transferVestedTokensToVault() external;

    /// @notice Retrieves the list of reward fuses.
    /// @return An array of addresses representing the reward fuses.
    function getRewardsFuses() external view returns (address[] memory);
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {VestingData} from "./ManagersStorageLib.sol";
import {FuseAction} from "../vaults/PlasmaVault.sol";

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
    /// @param fuse The address of the fuse to be checked.
    /// @return supported A boolean value indicating whether the reward fuse is supported.
    /// @dev This method checks the internal configuration to determine if the provided fuse address
    /// is supported for reward management.
    function isRewardFuseSupported(address fuse) external view returns (bool);

    /// @notice Retrieves the vesting data.
    /// @return vestingData A struct containing the vesting data.
    /// @dev This method returns the current state of the vesting data, including details such as
    /// the last update balance, the transferred tokens, and the timestamp of the last update.
    function getVestingData() external view returns (VestingData memory);

    /// @notice Transfers a specified amount of an asset to a given address.
    /// @param asset The address of the asset to be transferred.
    /// @param to The address of the recipient.
    /// @param amount The amount of the asset to be transferred, represented in the asset's decimals.
    /// @dev This method facilitates the transfer of a specified amount of the given asset from the contract to the recipient's address.
    function transfer(address asset, address to, uint256 amount) external;

    /// @notice Adds multiple reward fuses.
    /// @param fuses An array of addresses representing the fuses to be added.
    /// @dev This method adds the provided list of fuse addresses to the contract's configuration.
    /// It allows the inclusion of multiple fuses in a single transaction for reward management purposes.
    function addRewardFuses(address[] calldata fuses) external;

    /// @notice Removes a specified reward fuse.
    /// @param fuses The addresses of the fuse to be removed.
    /// @dev This method removes the provided fuse address from the contract's configuration.
    /// It is used to manage and update the list of supported reward fuses.
    function removeRewardFuses(address[] calldata fuses) external;

    /// @notice Claims rewards based on the provided fuse actions.
    /// @param calls An array of FuseAction structs representing the actions for claiming rewards.
    /// @dev This method processes the provided fuse actions to claim the corresponding rewards.
    /// Each FuseAction in the array is executed to facilitate the reward claim process.
    function claimRewards(FuseAction[] calldata calls) external;

    /// @notice Sets up the vesting schedule with a specified delay for token release.
    /// @param releaseTokensDelay The delay in seconds before the tokens are released.
    /// @dev This method configures the vesting schedule by setting the delay time for token release.
    /// The delay defines the period that must pass before the tokens can be released to the beneficiary.
    // @dev setting up this to zero will stopped vesting and freeze underling token on the contract
    function setupVestingTime(uint256 releaseTokensDelay) external;

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
}

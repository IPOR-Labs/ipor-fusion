// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title Interface for Euler reward token
interface IREUL {
    /// @notice Withdraws tokens to a specified account based on multiple normalized lock timestamps as per the lock
    /// schedule.
    /// The remainder of the tokens are transferred to the receiver address configured.
    /// @param account_ The address to receive the withdrawn tokens
    /// @param lockTimestamps_ An array of normalized lock timestamps to withdraw tokens for
    /// @param allowRemainderLoss_ If true, is it allowed for the remainder of the tokens to be transferred to the
    /// receiver address configured as per the lock schedule. If false and the calculated remainder amount is non-zero,
    /// the withdrawal will revert.
    /// @return bool indicating success of the withdrawal
    function withdrawToByLockTimestamps(
        address account_,
        uint256[] memory lockTimestamps_,
        bool allowRemainderLoss_
    ) external returns (bool);

    /// @notice Gets all the normalized lock timestamps of locked amounts for an account
    /// @param account The address to check
    /// @return An array of normalized lock timestamps
    function getLockedAmountsLockTimestamps(address account) external view returns (uint256[] memory);

    /// @notice Gets the number of locked amount entries for an account
    /// @param account The address to check
    /// @return The number of locked amount entries
    function getLockedAmountsLength(address account) external view returns (uint256);

    /// @notice Calculates the withdraw amounts for a given account and normalized lock timestamp
    /// @param account The address of the account to check
    /// @param lockTimestamp The normalized lock timestamp to check for withdraw amounts
    /// @return accountAmount The amount that can be unlocked and sent to the account
    /// @return remainderAmount The amount that will be transferred to the configured receiver address
    function getWithdrawAmountsByLockTimestamp(
        address account,
        uint256 lockTimestamp
    ) external view virtual returns (uint256, uint256);
}

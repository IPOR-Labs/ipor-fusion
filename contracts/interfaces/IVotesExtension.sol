// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IVotesExtension
/// @notice Interface for ERC20Votes extension-specific functions not in standard IVotes
/// @dev These functions are available in OpenZeppelin's ERC20VotesUpgradeable but not in IVotes interface
interface IVotesExtension {
    /// @notice Returns the number of checkpoints for an account
    /// @param account The address to get the number of checkpoints for
    /// @return The number of checkpoints
    function numCheckpoints(address account) external view returns (uint32);

    /// @notice Returns a checkpoint for an account
    /// @param account The address to get the checkpoint for
    /// @param pos The position of the checkpoint
    /// @return Checkpoint struct with fromBlock and votes
    function checkpoints(address account, uint32 pos) external view returns (Checkpoint208 memory);
}

/// @notice Checkpoint structure for vote tracking
struct Checkpoint208 {
    uint48 _key;
    uint208 _value;
}

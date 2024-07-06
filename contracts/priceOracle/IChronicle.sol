// SPDX-License-Identifier: MIT
pragma solidity ^0.8.16;

/**
 * @title IChronicle
 * @dev Interface for Chronicle Protocol's oracle
 * https://github.com/chronicleprotocol/chronicle-std/blob/main/src/IChronicle.sol
 */
interface IChronicle {
    /// @notice Returns the oracle's current value.
    /// @dev Reverts if no value set.
    /// @return value The oracle's current value.
    function read() external view returns (uint value);
}

interface IToll {
    /// @notice Grants address `who` toll.
    /// @dev Only callable by auth'ed address.
    /// @param who The address to grant toll.
    function kiss(address who) external;
}

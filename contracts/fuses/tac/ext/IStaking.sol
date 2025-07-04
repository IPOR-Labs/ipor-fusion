// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

struct Coin {
    string denom;
    uint256 amount;
}

/// @dev Represents a single entry of an unbonding delegation.
struct UnbondingDelegationEntry {
    int64 creationHeight;
    int64 completionTime;
    uint256 initialBalance;
    uint256 balance;
    uint64 unbondingId;
    int64 unbondingOnHoldRefCount;
}

/// @dev Represents the output of the UnbondingDelegation query.
struct UnbondingDelegationOutput {
    string delegatorAddress;
    string validatorAddress;
    UnbondingDelegationEntry[] entries;
}

/// @title IStaking interface
/// @notice Interface for the staking contract based on Cosmos EVM staking precompile
interface IStaking {
    function delegation(
        address delegatorAddress,
        string memory validatorAddress
    ) external view returns (uint256 shares, Coin memory balance);

    function unbondingDelegation(
        address delegatorAddress,
        string memory validatorAddress
    ) external view returns (UnbondingDelegationOutput memory unbondingDelegation);

    function delegate(
        address delegatorAddress,
        string memory validatorAddress,
        uint256 amount
    ) external returns (bool success);

    function undelegate(
        address delegatorAddress,
        string memory validatorAddress,
        uint256 amount
    ) external returns (bool success);
}

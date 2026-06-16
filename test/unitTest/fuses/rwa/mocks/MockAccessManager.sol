// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @title MockAccessManager
/// @notice Minimal mock of `IAccessManager` for RWA unit tests — only `hasRole` is used by
///         `RWAUnpauseFuse`.
contract MockAccessManager {
    mapping(uint64 role => mapping(address account => bool isMember)) public roles;

    function grantRole(uint64 role_, address account_) external {
        roles[role_][account_] = true;
    }

    function revokeRole(uint64 role_, address account_) external {
        roles[role_][account_] = false;
    }

    /// @notice Mirrors the signature of OpenZeppelin `IAccessManager.hasRole`.
    function hasRole(uint64 role_, address account_) external view returns (bool isMember, uint32 executionDelay) {
        isMember = roles[role_][account_];
        executionDelay = 0;
    }
}

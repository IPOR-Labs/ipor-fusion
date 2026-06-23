// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IEulerV2SwapRegistry
/// @notice Minimal interface for the EulerSwap v2 registry, transcribed from
///         euler-xyz/euler-swap tag `eulerswap-2.0`
///         (commit 81cf6dc988468fd56f690e6bc0e338a5be02d034), `src/interfaces/IEulerV2SwapRegistry.sol`.
/// @dev In v2 registration (and the validity bond), pool enumeration and `poolByEulerAccount`
///      lookups live on the Registry rather than the factory.
interface IEulerV2SwapRegistry {
    /// @notice Registers `pool` in the public registry, posting the validity bond as msg.value.
    function registerPool(address pool) external payable;

    /// @notice Unregisters the caller's currently registered pool and refunds its validity bond.
    function unregisterPool() external;

    /// @notice Returns the registered pool for a given EVC account, or address(0) if none.
    function poolByEulerAccount(address who) external view returns (address pool);

    /// @notice Returns the validity bond currently locked for `pool`.
    function validityBond(address pool) external view returns (uint256);

    /// @notice Returns the minimum validity bond required to register a pool.
    function minimumValidityBond() external view returns (uint256);
}

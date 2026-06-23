// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IEulerV2Swap} from "./IEulerV2Swap.sol";

/// @title IEulerV2SwapFactory
/// @notice Minimal interface for the EulerSwap v2 factory, transcribed from
///         euler-xyz/euler-swap tag `eulerswap-2.0`
///         (commit 81cf6dc988468fd56f690e6bc0e338a5be02d034), `src/interfaces/IEulerV2SwapFactory.sol`.
/// @dev In v2 the factory only deploys pools and tracks deployment status. Pool enumeration and
///      `poolByEulerAccount` lookups live on the Registry (see {IEulerV2SwapRegistry}).
interface IEulerV2SwapFactory {
    /// @notice Deploys a new EulerSwap pool via CREATE2.
    /// @dev The factory requires the pool address (derived from `staticParams` + `salt`) to already be
    ///      authorized as the EVC account operator of `staticParams.eulerAccount` before this call.
    /// @return pool The address of the freshly deployed pool.
    function deployPool(
        IEulerV2Swap.StaticParams memory staticParams,
        IEulerV2Swap.DynamicParams memory dynamicParams,
        IEulerV2Swap.InitialState memory initialState,
        bytes32 salt
    ) external returns (address pool);

    /// @notice Computes the deterministic CREATE2 address for the given static params and salt.
    function computePoolAddress(
        IEulerV2Swap.StaticParams memory staticParams,
        bytes32 salt
    ) external view returns (address pool);

    /// @notice Returns true if `pool` was deployed by this factory.
    function deployedPools(address pool) external view returns (bool);
}

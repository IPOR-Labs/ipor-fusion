// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IEulerV2Swap
/// @notice Minimal interface for the EulerSwap v2 pool, transcribed from
///         euler-xyz/euler-swap tag `eulerswap-2.0`
///         (commit 81cf6dc988468fd56f690e6bc0e338a5be02d034), `src/interfaces/IEulerV2Swap.sol`.
/// @dev Only the structs and functions consumed by the Fusion EulerSwap fuses are declared here.
///      The field order and widths of `StaticParams` / `DynamicParams` / `InitialState` are
///      load-bearing for ABI encoding of `IEulerV2SwapFactory.deployPool` and MUST match the
///      deployed factory implementation on the target network.
interface IEulerV2Swap {
    /// @notice Immutable configuration of a pool, fixed at deployment time.
    /// @param supplyVault0 Euler vault holding asset0 collateral for the LP account
    /// @param supplyVault1 Euler vault holding asset1 collateral for the LP account
    /// @param borrowVault0 Euler vault asset0 is borrowed from (just-in-time liquidity)
    /// @param borrowVault1 Euler vault asset1 is borrowed from (just-in-time liquidity)
    /// @param eulerAccount The EVC account that owns the LP position (our vault sub-account)
    /// @param feeRecipient Recipient of swap fees (address(0) => fees compound into the supply vault)
    struct StaticParams {
        address supplyVault0;
        address supplyVault1;
        address borrowVault0;
        address borrowVault1;
        address eulerAccount;
        address feeRecipient;
    }

    /// @notice Mutable curve / fee configuration, updatable via `reconfigure`.
    struct DynamicParams {
        uint112 equilibriumReserve0;
        uint112 equilibriumReserve1;
        uint112 minReserve0;
        uint112 minReserve1;
        uint80 priceX;
        uint80 priceY;
        uint64 concentrationX;
        uint64 concentrationY;
        uint64 fee0;
        uint64 fee1;
        uint40 expiration;
        uint8 swapHookedOperations;
        address swapHook;
    }

    /// @notice Initial virtual reserves used when (re)activating the pool curve.
    struct InitialState {
        uint112 reserve0;
        uint112 reserve1;
    }

    /// @notice Activates the pool with the given dynamic parameters and initial state.
    /// @dev Called by the factory during deployment; included for completeness.
    function activate(DynamicParams calldata dynamicParams, InitialState calldata initialState) external;

    /// @notice Updates the mutable curve parameters and resets the virtual reserves.
    function reconfigure(DynamicParams calldata dynamicParams, InitialState calldata initialState) external;

    /// @notice Returns the immutable configuration of the pool.
    function getStaticParams() external view returns (StaticParams memory);

    /// @notice Returns the current mutable configuration of the pool.
    function getDynamicParams() external view returns (DynamicParams memory);

    /// @notice Returns the underlying assets traded by the pool.
    function getAssets() external view returns (address asset0, address asset1);

    /// @notice Returns the current virtual reserves and curve status.
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 status);
}

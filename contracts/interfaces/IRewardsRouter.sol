// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IRewardsRouter
/// @notice Interface for the generic, per-vault rewards claim router.
/// @dev The router batches a list of low-level calls so the keeper can perform a full
/// "claim (+ redeem/swap) -> vest" rewards flow in a single transaction.
interface IRewardsRouter {
    /// @notice A single low-level call to be executed as part of a batch.
    /// @param target The contract to call.
    /// @param data The ABI-encoded calldata for the call.
    struct ExecuteCall {
        address target;
        bytes data;
    }

    /// @notice Executes a batch of calls in a single transaction, in order.
    /// @param calls_ The ordered list of calls to execute.
    /// @return results The return data of each call, in the same order.
    function execute(ExecuteCall[] calldata calls_) external returns (bytes[] memory results);

    /// @notice Transfers the router's entire balance of `asset_` to `to_`. Callable only as a step within
    /// {execute} (self-call gated), so a batch can vest exactly the swapped amount with no off-chain pinning.
    /// @param asset_ The ERC20 to flush.
    /// @param to_ The recipient of the full balance.
    function transferAll(address asset_, address to_) external;

    /// @notice The PlasmaVault this router is permanently bound to.
    function PLASMA_VAULT() external view returns (address);

    /// @notice The IporFusionAccessManager (authority) this router is bound to.
    function ACCESS_MANAGER() external view returns (address);
}

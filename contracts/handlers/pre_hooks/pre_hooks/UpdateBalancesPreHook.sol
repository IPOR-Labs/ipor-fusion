// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPreHook} from "../IPreHook.sol";
import {PlasmaVault} from "../../../vaults/PlasmaVault.sol";
import {FusesLib} from "../../../libraries/FusesLib.sol";

/// @title UpdateBalancesPreHook
/// @notice Pre-execution hook for updating balances in Plasma Vault
/// @dev This contract implements the IPreHook interface to update market balances before vault operations.
///      It serves as a basic implementation that updates all active market balances without filtering.
///
/// Key features:
/// - Updates all active market balances
/// - No configuration required
/// - Simple and straightforward implementation
/// - Minimal gas overhead
///
/// Security considerations:
/// - Protected by PlasmaVault's access control
/// - No external configuration dependencies
/// - Atomic balance updates for all markets
/// - Refreshes every active market, so on a vault with a live EulerSwap pool it makes a user operation
///   a trigger for refreshing the EULER_V2 market (11), which must not be reachable from user operations
///   there (IL-9331). This also holds when the hook is nested in ExchangeRateValidatorPreHook, and for
///   markets whose dependency graph (expanded recursively) contains market 11. See the Euler fuses README.
/// - On a vault that holds a child PlasmaVault, the hook turns every hooked user operation into a read of the
///   child's share price, which can be temporarily wrong while the child runs its `execute` batch or an instant
///   withdrawal. This also holds when the hook is nested in ExchangeRateValidatorPreHook. Known limitation, no
///   code guard (owner decision); see "Transient share-price views during `execute` and instant withdrawal (IL-9631, IL-9743)" in contracts/vaults/README.md.
///
/// Comparison with UpdateBalancesIgnoreDustPreHook:
/// - No dust threshold filtering
/// - Updates all markets regardless of balance size
/// - Lower implementation complexity
/// - Higher gas usage for many small balance markets
///
/// ContextManager (runWithContext / runWithContextAndSignature):
/// - The hook calls PlasmaVault(address(this)).updateMarketsBalances. PlasmaVault authorizes its own
///   self-calls against the vault, so relayed calls on hooked selectors work like direct calls (IL-8310).
/// - Vaults created from a PlasmaVault implementation that predates IL-8310 authorize this self-call
///   against the context sender instead. There, a relayed call on a hooked selector reverts with
///   AccessManagedUnauthorized unless the context sender itself holds UPDATE_MARKETS_BALANCES_ROLE;
///   direct calls are not affected. The same applies when the hook is nested under
///   ExchangeRateValidatorPreHook. Such vaults must treat relayed user operations on hooked selectors
///   as unsupported, or move users to a vault created from a fixed implementation. Do not remove the
///   vault from ContextManager's approved targets (admin batches rely on it) and do not make
///   updateMarketsBalances public as a workaround.
contract UpdateBalancesPreHook is IPreHook {
    /// @notice Executes the pre-hook logic to update all active market balances
    /// @dev This function:
    ///      1. Retrieves all active markets from balance fuses
    ///      2. Updates balances for all active markets
    ///
    /// The process involves:
    /// - Getting the list of active markets from FusesLib
    /// - Calling updateMarketsBalances on PlasmaVault with all markets
    ///
    /// Gas optimization:
    /// - Early return if no active markets
    /// - Single storage operation for market updates
    /// - No intermediate array operations
    ///
    /// @param selector_ The function selector that triggered this pre-hook
    function run(bytes4 selector_) external {
        uint256[] memory marketIds = FusesLib.getActiveMarketsInBalanceFuses();
        if (marketIds.length == 0) {
            return;
        }
        PlasmaVault(address(this)).updateMarketsBalances(marketIds);
    }
}

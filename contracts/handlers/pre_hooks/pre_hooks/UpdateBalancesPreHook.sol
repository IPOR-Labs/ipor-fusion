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
///
/// Comparison with UpdateBalancesIgnoreDustPreHook:
/// - No dust threshold filtering
/// - Updates all markets regardless of balance size
/// - Lower implementation complexity
/// - Higher gas usage for many small balance markets
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

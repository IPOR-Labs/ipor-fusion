// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPreHook} from "../IPreHook.sol";
import {PlasmaVault} from "../../../vaults/PlasmaVault.sol";
import {FusesLib} from "../../../libraries/FusesLib.sol";
import {PlasmaVaultLib} from "../../../libraries/PlasmaVaultLib.sol";
import {PreHooksLib} from "../PreHooksLib.sol";

/// @title UpdateBalancesIgnoreDustPreHook
/// @notice Pre-execution hook for updating balances in Plasma Vault while ignoring dust amounts
/// @dev This contract implements the IPreHook interface to update market balances before vault operations
///      It filters out markets with balances below a configurable dust threshold to optimize gas costs
///      and prevent unnecessary updates for insignificant amounts.
///
/// Key features:
/// - Configurable dust threshold through substrates
/// - Filters out markets whose cached balance is below the dust threshold
/// - Refreshes only markets whose cached balance is at or above the threshold, plus their dependency graphs
/// - Gas efficient implementation using dynamic arrays
///
/// Substrates Configuration:
/// - The contract expects exactly one substrate value configured through PlasmaVaultGovernance
/// - The substrate value is the dust threshold in the underlying asset's decimals (not WAD, not 18 decimals)
/// - Example: For USDC (6 decimals), a substrate value of 1e6 means 1 USDC dust threshold
/// - A value written in 18 decimals on a 6-decimal asset (1e18 on USDC = 1e12 USDC) puts every market
///   below the threshold: the hook then refreshes nothing and does not revert
/// - Markets whose cached balance (the value stored by the previous balance update, read via
///   PlasmaVaultLib.getTotalAssetsInMarket) is below this threshold are left out of the refresh list
/// - The filter does not read the live balance from the balance fuse. A market left out of the list is
///   still refreshed when it is in the balance dependency graph of a market at or above the threshold.
///   Otherwise its cached value, and therefore totalAssets, stays stale until one of: execute on that
///   market or on a market whose dependency graph includes it, UpdateMarketsBalancesFuse, an instant
///   withdrawal from that market (withdraw / redeem / redeemFromRequest), or an explicit
///   updateMarketsBalances call (e.g. by a keeper)
/// - A market whose balance fuse reads below the threshold even once (e.g. 0 during a transient failure
///   of the venue or its oracle) is cached below the threshold and is not re-read by this hook afterwards.
///   UpdateBalancesPreHook does not have this limitation
/// - This configuration is set during hook registration via setPreHookImplementations
///
/// Example substrate configuration from tests:
/// ```solidity
/// bytes32[][] memory preHookSubstrates = new bytes32[][](1);
/// preHookSubstrates[0] = new bytes32[](1);
/// preHookSubstrates[0][0] = bytes32(uint256(1e6)); // 1 USDC dust threshold
/// ```
///
/// Security considerations:
/// - Immutable version address for substrate lookup
/// - Validates substrate configuration
/// - Protected by PlasmaVault's access control
/// - Dust threshold can only be modified by governance
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
contract UpdateBalancesIgnoreDustPreHook is IPreHook {
    /// @notice Immutable version address used for substrate configuration lookup
    /// @dev This address is set during construction and used to retrieve the dust threshold
    address public immutable VERSION;

    /// @notice Error thrown when price oracle middleware is not properly configured
    error PriceOracleMiddlewareNotSet();

    /// @notice Error thrown when the substrates array does not contain exactly one element (dust threshold)
    /// @dev The substrates array must contain exactly one element representing the dust threshold
    error InvalidSubstratesLength();

    /// @notice Initializes the pre-hook with its version address
    /// @dev Sets the VERSION to the deployed contract address for substrate configuration lookup
    constructor() {
        VERSION = address(this);
    }

    /// @notice Executes the pre-hook logic to update market balances
    /// @dev This function:
    ///      1. Retrieves active markets from balance fuses
    ///      2. Gets the dust threshold from substrates
    ///      3. Filters markets based on the dust threshold
    ///      4. Updates balances for markets whose cached balance is at or above the threshold
    ///
    /// The process involves:
    /// - Reading the dust threshold from substrates[0]
    /// - Checking each market's cached balance (not its live balance) against the threshold
    /// - Creating a filtered list of markets to update
    /// - Calling updateMarketsBalances on the PlasmaVault
    ///
    /// Gas optimization:
    /// - Early return if no active markets
    /// - Skips markets with dust amounts
    /// - Minimizes storage reads and array operations
    ///
    /// @param selector_ The function selector that triggered this pre-hook
    function run(bytes4 selector_) external {
        uint256[] memory marketIds = FusesLib.getActiveMarketsInBalanceFuses();
        uint256 marketsLength = marketIds.length;
        if (marketsLength == 0) {
            return;
        }

        /// @dev substrates[0] is the dust threshold in underlying asset of PlasmaVault
        bytes32[] memory substrates = PreHooksLib.getPreHookSubstrates(selector_, VERSION);
        if (substrates.length != 1) {
            revert InvalidSubstratesLength();
        }

        uint256 dustThreshold = uint256(substrates[0]);

        uint256 nonDustMarketIdsLength;
        uint256[] memory nonDustMarketIds = new uint256[](marketIds.length);

        uint256 marketId;
        uint256 marketBalance;
        for (uint256 i; i < marketsLength; i++) {
            marketId = marketIds[i];
            marketBalance = PlasmaVaultLib.getTotalAssetsInMarket(marketId);
            if (marketBalance >= dustThreshold) {
                nonDustMarketIds[nonDustMarketIdsLength] = marketId;
                nonDustMarketIdsLength++;
            }
        }

        if (nonDustMarketIdsLength == 0) {
            return;
        }

        uint256[] memory marketsToUpdate = new uint256[](nonDustMarketIdsLength);
        for (uint256 i; i < nonDustMarketIdsLength; i++) {
            marketsToUpdate[i] = nonDustMarketIds[i];
        }

        PlasmaVault(address(this)).updateMarketsBalances(marketsToUpdate);
    }
}

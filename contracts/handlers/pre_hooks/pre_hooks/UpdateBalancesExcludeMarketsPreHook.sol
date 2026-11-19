// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPreHook} from "../IPreHook.sol";
import {PlasmaVault} from "../../../vaults/PlasmaVault.sol";
import {FusesLib} from "../../../libraries/FusesLib.sol";
import {PreHooksLib} from "../PreHooksLib.sol";

/// @title UpdateBalancesExcludeMarketsPreHook
/// @notice Pre-execution hook that refreshes the balances of all active markets except a configured list
/// @dev Behaves like UpdateBalancesPreHook, but the substrates of the hook are market ids that this hook never
///      passes to `updateMarketsBalances`. Its purpose is a vault with a live EulerSwap pool: the EULER_V2 market (11)
///      must not be refreshed by a user operation (IL-9331, see the Euler fuses README), and with
///      UpdateBalancesPreHook the vault would have to give up refreshing every other market on user entry points
///      too. Wire this hook with market 11 as the excluded market instead.
///
///      The exclusion list also keeps the market that values a child PlasmaVault out of user-triggered refreshes,
///      with the caveats of market 11 (dependency graph, instant withdrawal entry, registration directly on every
///      selector the user can call) and with direct access to updateMarketsBalances limited to trusted operators.
///      A selector has one hook, so registering this one replaces the existing hook and its substrates: replace a
///      plain refresher only, and where ExchangeRateValidatorPreHook hosts nested refreshers remove them and keep
///      the validator (a nested exclusion hook excludes nothing).
///      See "Transient share-price views during `execute` and instant withdrawal (IL-9631, IL-9743)" in contracts/vaults/README.md.
///
/// Substrates Configuration (set through PlasmaVaultGovernance.setPreHookImplementations):
/// - Each substrate is one excluded market id (uint256 cast to bytes32); the number of substrates is not limited
/// - An empty list excludes nothing: the hook then behaves exactly like UpdateBalancesPreHook
/// - A market id of 0 is rejected with InvalidExcludedMarketId (a zero substrate is a configuration mistake)
/// - A listed market that is not active, or a market listed twice, is harmless
///
/// What the hook does NOT guarantee:
/// - It only filters the list that THIS hook passes to updateMarketsBalances. PlasmaVault expands the dependency
///   balance graph of every refreshed market recursively, so an excluded market is still refreshed when it is in
///   the graph of a market that is refreshed (for example when some market has an edge to market 11). The
///   configuration rules of the Euler fuses README stay: no dependency edge to market 11 from a market that user
///   operations refresh, and no instant withdraw from market 11 on a vault with a live pool.
/// - It cannot be nested in ExchangeRateValidatorPreHook: a nested hook receives no substrates, so the exclusion list
///   would be empty and the hook would refresh every market, including the excluded one. Register it directly on
///   the selector.
/// - A market that is excluded keeps a stale cached balance until the keeper or the alpha refreshes it
///   (updateMarketsBalances, execute); see the stale-cache note in the Euler fuses README. That refresh is a public
///   transaction and can be sandwiched, so submit it privately.
///
/// Hooks V2 (IL-9490) port invariant: the V2 port of this hook must keep the same behaviour. Invariant: a market
/// id configured as excluded is never an element of the array the hook passes to updateMarketsBalances, every
/// other active market is, and an empty list means "refresh all active markets". The port must also take the
/// exclusion list from the hook configuration of the selector it runs on, and must not be nestable without it.
///
/// ContextManager (runWithContext / runWithContextAndSignature):
/// - The hook calls PlasmaVault(address(this)).updateMarketsBalances, same as UpdateBalancesPreHook. See the NatSpec
///   of UpdateBalancesPreHook for vaults whose implementation predates IL-8310.
contract UpdateBalancesExcludeMarketsPreHook is IPreHook {
    /// @notice Immutable version address used for substrate configuration lookup
    /// @dev Set to the deployed contract address; the hook runs by delegatecall in the vault, where address(this) is
    ///      the vault, so the address of the implementation must be remembered for the substrate key
    address public immutable VERSION;

    /// @notice Error thrown when an excluded market id substrate is 0
    error InvalidExcludedMarketId();

    constructor() {
        VERSION = address(this);
    }

    /// @notice Refreshes every active market that is not in the exclusion list of the hook
    /// @dev 1. Reads the active markets from the balance fuses
    ///      2. Reads the excluded market ids from the substrates registered for `selector_`
    ///      3. Calls updateMarketsBalances with the active markets that are not excluded (nothing if none is left)
    /// @param selector_ The function selector that triggered this pre-hook
    function run(bytes4 selector_) external {
        uint256[] memory marketIds = FusesLib.getActiveMarketsInBalanceFuses();
        uint256 marketsLength = marketIds.length;
        if (marketsLength == 0) {
            return;
        }

        bytes32[] memory excluded = PreHooksLib.getPreHookSubstrates(selector_, VERSION);
        uint256 excludedLength = excluded.length;
        for (uint256 i; i < excludedLength; ++i) {
            if (excluded[i] == bytes32(0)) {
                revert InvalidExcludedMarketId();
            }
        }

        uint256[] memory kept = new uint256[](marketsLength);
        uint256 count;
        for (uint256 i; i < marketsLength; ++i) {
            if (!_isExcluded(marketIds[i], excluded)) {
                kept[count] = marketIds[i];
                ++count;
            }
        }

        if (count == 0) {
            return;
        }

        uint256[] memory marketsToUpdate = new uint256[](count);
        for (uint256 i; i < count; ++i) {
            marketsToUpdate[i] = kept[i];
        }

        PlasmaVault(address(this)).updateMarketsBalances(marketsToUpdate);
    }

    function _isExcluded(uint256 marketId_, bytes32[] memory excluded_) private pure returns (bool) {
        uint256 length = excluded_.length;
        for (uint256 i; i < length; ++i) {
            if (uint256(excluded_[i]) == marketId_) {
                return true;
            }
        }
        return false;
    }
}

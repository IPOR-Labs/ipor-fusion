// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPreHook} from "../IPreHook.sol";
import {PlasmaVault} from "../../../vaults/PlasmaVault.sol";
import {FusesLib} from "../../../libraries/FusesLib.sol";
import {IporFusionMarkets} from "../../../libraries/IporFusionMarkets.sol";
import {HyperCoreHookWiringLib} from "../../../fuses/hypercore/lib/HyperCoreHookWiringLib.sol";
import {PreHooksLib} from "../PreHooksLib.sol";
import {HyperCoreCapitalFlowGatesLib} from "./HyperCoreCapitalFlowGatesLib.sol";

/// @title HyperCoreCapitalFlowFullRefreshPreHook
/// @notice Capital-flow pre-hook for vaults that mix HyperCore (market 55) with other markets (IL-9628). It enforces
///         the same gates as `HyperCoreCapitalFlowPreHook`, then refreshes market 55 together with every other active
///         balance-fuse market except the markets listed as exclusions, so share pricing never reads a stale cache of
///         the other markets.
/// @dev INVARIANT (a Hooks V2 port, IL-9490, must keep it): before a share-priced flow is priced, the gates of
///      `HyperCoreCapitalFlowGatesLib.enforcePricingGates()` pass, and market 55 plus every active balance-fuse market
///      that is not excluded is refreshed in one `updateMarketsBalances` call. Market 55 is always refreshed and can
///      not be excluded.
///
///      Why: `HyperCoreCapitalFlowPreHook` refreshes market 55 only. On a mixed vault the other markets are priced
///      from their cache on deposit and withdraw, and a vault can have one hook per selector, so a second refresh hook
///      cannot be added next to it.
///
///      Wiring: same as `HyperCoreCapitalFlowPreHook`. Register one instance on deposit, depositWithPermit, mint,
///      withdraw, redeem and redeemFromRequest; `HyperCorePendingActionPreHook` stays on execute and
///      updateMarketsBalances. The hook exposes the same marker `HYPERCORE_CAPITAL_FLOW_PRE_HOOK_ID()`, so the
///      HyperCore action fuses accept it as the capital-flow hook (`HyperCoreHookWiringLib.requireCapitalFlowWired`).
///      The vault must grant itself UPDATE_MARKETS_BALANCES_ROLE. Under `execute` and `updateMarketsBalances` the hook
///      reverts with `HyperCorePreHookWrongSelector`. The ContextManager notes of `HyperCoreCapitalFlowPreHook` apply
///      unchanged.
///
///      Exclusions: the substrates registered for the hook on a selector (`setPreHookImplementations`) are market
///      ids (`bytes32(marketId)`) that are NOT refreshed. Use them for markets that a user operation must not refresh,
///      for example the market of an EulerSwap pool (IL-9535). An empty list refreshes everything, so a market added
///      later is refreshed by default. Register the same list on all six selectors. An entry equal to the HyperCore
///      market id is ignored. An excluded market keeps its cached
///      value only when no active market has a dependency edge to it: `updateMarketsBalances` expands the dependency
///      balance graph of every refreshed market recursively, so an excluded market in that graph is still refreshed
///      (the same caveat as `UpdateBalancesExcludeMarketsPreHook`).
///
///      Cost: every flow refreshes every active market (roughly 30-150k gas per market). A market that reverts in its
///      balance fuse blocks every share-priced flow until it is excluded or fixed; the exclusion list is the escape
///      hatch.
contract HyperCoreCapitalFlowFullRefreshPreHook is IPreHook {
    /// @notice Immutable address used to look up the exclusion substrates (`address(this)` is the vault when run).
    address public immutable VERSION;

    /// @notice The hook was run under a selector it must not be wired on.
    error HyperCorePreHookWrongSelector(bytes4 selector);

    constructor() {
        VERSION = address(this);
    }

    /// @notice Marker identifying a HyperCore capital-flow hook; read by `HyperCoreHookWiringLib`.
    function HYPERCORE_CAPITAL_FLOW_PRE_HOOK_ID() external pure returns (bytes32) {
        return HyperCoreHookWiringLib.CAPITAL_FLOW_PRE_HOOK_ID;
    }

    function run(bytes4 selector_) external {
        if (selector_ == PlasmaVault.execute.selector || selector_ == PlasmaVault.updateMarketsBalances.selector) {
            revert HyperCorePreHookWrongSelector(selector_);
        }
        HyperCoreCapitalFlowGatesLib.enforcePricingGates();

        bytes32[] memory excluded_ = PreHooksLib.getPreHookSubstrates(selector_, VERSION);
        uint256[] memory active_ = FusesLib.getActiveMarketsInBalanceFuses();
        uint256 activeLength_ = active_.length;

        uint256[] memory markets_ = new uint256[](activeLength_ + 1);
        markets_[0] = IporFusionMarkets.HYPERCORE;
        uint256 count_ = 1;
        for (uint256 i; i < activeLength_; ++i) {
            uint256 marketId_ = active_[i];
            if (marketId_ == IporFusionMarkets.HYPERCORE || _isExcluded(excluded_, marketId_)) {
                continue;
            }
            markets_[count_++] = marketId_;
        }
        // shrink the array to the number of markets to refresh
        assembly {
            mstore(markets_, count_)
        }
        PlasmaVault(address(this)).updateMarketsBalances(markets_);
    }

    function _isExcluded(bytes32[] memory excluded_, uint256 marketId_) private pure returns (bool) {
        uint256 length_ = excluded_.length;
        for (uint256 i; i < length_; ++i) {
            if (uint256(excluded_[i]) == marketId_) {
                return true;
            }
        }
        return false;
    }
}

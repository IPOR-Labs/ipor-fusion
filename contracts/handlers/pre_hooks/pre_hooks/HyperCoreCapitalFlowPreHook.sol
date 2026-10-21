// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPreHook} from "../IPreHook.sol";
import {PlasmaVault} from "../../../vaults/PlasmaVault.sol";
import {IporFusionMarkets} from "../../../libraries/IporFusionMarkets.sol";
import {HyperCorePendingLib} from "../../../fuses/hypercore/lib/HyperCorePendingLib.sol";
import {HyperCoreValuationLib} from "../../../fuses/hypercore/lib/HyperCoreValuationLib.sol";
import {HyperCoreHookWiringLib} from "../../../fuses/hypercore/lib/HyperCoreHookWiringLib.sol";

/// @title HyperCoreCapitalFlowPreHook
/// @notice Blocks share-priced capital flows while HyperCore state is pending (or, until the next Core L1 block,
///         while a TIMING order sent in the current block is unprocessed), then refreshes
///         the HyperCore market so current positions, funding and fills are used for pricing.
/// @dev Register one instance for deposit, depositWithPermit, mint, withdraw, redeem and
///      redeemFromRequest. The vault must grant itself UPDATE_MARKETS_BALANCES_ROLE. Do not
///      route these selectors through ContextManager: its sender substitution breaks the nested
///      updateMarketsBalances call (IL-8310). Wiring it on execute or updateMarketsBalances is a
///      misconfiguration (recursion / settlement deadlock), so the hook reverts with
///      HyperCorePreHookWrongSelector under those selectors (IL-8529). HyperCorePendingActionPreHook
///      is the hook for execute and updateMarketsBalances.
///      After the wrong-selector check it first latches a settled record
///      (`HyperCorePendingLib.settleIfReady()`: clears it and emits HyperCoreActionSettled), so later balance
///      changes cannot re-open the pending state.
///      After the pending checks and before the refresh it enforces the IL-8534 mark-vs-Core-oracle band
///      (`HyperCoreValuationLib.checkMarkOracleBand`): share-priced flows revert while a held perp market's mark
///      deviates from the Core oracle by more than `MaxMarkOracleDeviationBps`. Execute, refreshes, TIMING
///      orders and cancels are not gated, so the manager can de-risk while prices diverge.
///      The hook exposes the marker `HYPERCORE_CAPITAL_FLOW_PRE_HOOK_ID()`. A missing or foreign hook on a flow
///      selector runs no HyperCore code, so hook code cannot detect it; the HyperCore action fuses catch it instead
///      (`HyperCoreHookWiringLib.requireCapitalFlowWired`, IL-8529).
contract HyperCoreCapitalFlowPreHook is IPreHook {
    /// @notice The hook was run under a selector it must not be wired on.
    error HyperCorePreHookWrongSelector(bytes4 selector);

    /// @notice Marker identifying this hook; the HyperCore action fuses read it through
    ///         `HyperCoreHookWiringLib.requireCapitalFlowWired` before creating Core exposure.
    function HYPERCORE_CAPITAL_FLOW_PRE_HOOK_ID() external pure returns (bytes32) {
        return HyperCoreHookWiringLib.CAPITAL_FLOW_PRE_HOOK_ID;
    }

    function run(bytes4 selector_) external {
        if (selector_ == PlasmaVault.execute.selector || selector_ == PlasmaVault.updateMarketsBalances.selector) {
            revert HyperCorePreHookWrongSelector(selector_);
        }
        HyperCorePendingLib.settleIfReady();
        HyperCorePendingLib.requireNotPendingAction();
        HyperCorePendingLib.requireNoOrderInFlight();
        HyperCoreValuationLib.checkMarkOracleBand(IporFusionMarkets.HYPERCORE);

        uint256[] memory markets_ = new uint256[](1);
        markets_[0] = IporFusionMarkets.HYPERCORE;
        PlasmaVault(address(this)).updateMarketsBalances(markets_);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPreHook} from "../IPreHook.sol";
import {PlasmaVault} from "../../../vaults/PlasmaVault.sol";
import {HyperCorePendingLib} from "../../../fuses/hypercore/lib/HyperCorePendingLib.sol";

/// @title HyperCorePendingActionPreHook
/// @notice Prevents ordinary execute/update calls from bypassing a pending HyperCore action.
/// @dev Register for execute and external updateMarketsBalances. There is no caller exception (IL-8543 removed the
///      settlement reporter): while a transfer is pending, execute and external updateMarketsBalances revert for
///      every caller. Action fuses independently enforce the same guard.
///      Must NOT be wired on the share-priced flows (deposit, depositWithPermit, mint, withdraw,
///      redeem, redeemFromRequest): those need HyperCoreCapitalFlowPreHook, which refreshes the
///      market before pricing. Under those selectors the hook reverts with
///      HyperCorePreHookWrongSelector, even when nothing is pending (IL-8529).
///      After the wrong-selector check it first latches a settled record
///      (`HyperCorePendingLib.settleIfReady()`: clears it and emits HyperCoreActionSettled), so later balance
///      changes cannot re-open the pending state.
contract HyperCorePendingActionPreHook is IPreHook {
    /// @notice The hook was run under a selector it must not be wired on.
    error HyperCorePreHookWrongSelector(bytes4 selector);

    function run(bytes4 selector_) external {
        if (
            selector_ == PlasmaVault.deposit.selector ||
            selector_ == PlasmaVault.depositWithPermit.selector ||
            selector_ == PlasmaVault.mint.selector ||
            selector_ == PlasmaVault.withdraw.selector ||
            selector_ == PlasmaVault.redeem.selector ||
            selector_ == PlasmaVault.redeemFromRequest.selector
        ) {
            revert HyperCorePreHookWrongSelector(selector_);
        }

        HyperCorePendingLib.settleIfReady();

        if (!HyperCorePendingLib.isActionPending()) return;

        HyperCorePendingLib.requireNotPendingAction();
    }
}

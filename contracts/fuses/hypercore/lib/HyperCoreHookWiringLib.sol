// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PlasmaVault} from "../../../vaults/PlasmaVault.sol";
import {PreHooksLib} from "../../../handlers/pre_hooks/PreHooksLib.sol";

/// @title HyperCoreHookWiringLib
/// @notice Positive check of the HyperCore pre-hook wiring (IL-8529). A missing or foreign hook on a share-priced
///         selector runs no HyperCore code, so hook code cannot detect it. The code that runs anyway checks it
///         instead: the action fuses, before creating Core exposure.
/// @dev Runs in the vault context (fuses are delegatecalled), so PreHooksLib reads the vault's own config.
///      Limitations: a later re-wiring after exposure exists is NOT detected by this check (the unhooked selector
///      runs no HyperCore code); it only blocks the next exposure-creating action. Reduce-only orders, margin, send,
///      cancel and builder-fee actions are not gated, so a mis-wired vault can still unwind.
library HyperCoreHookWiringLib {
    /// @dev Returned by `HyperCoreCapitalFlowPreHook.HYPERCORE_CAPITAL_FLOW_PRE_HOOK_ID()`.
    bytes32 internal constant CAPITAL_FLOW_PRE_HOOK_ID = keccak256("ipor.fusion.hypercore.CapitalFlowPreHook");

    /// @notice A share-priced selector is not wired to the HyperCore CapitalFlow pre-hook.
    error HyperCorePreHooksNotWired(bytes4 selector, address implementation);

    /// @notice Reverts unless all six share-priced selectors are wired to one HyperCoreCapitalFlowPreHook.
    /// @dev Identifies the hook by its marker (misconfiguration guard, not an access control: governance can
    ///      install any code anyway). 6 SLOADs + 1 staticcall.
    function requireCapitalFlowWired() internal view {
        address hook = PreHooksLib.getPreHookImplementation(PlasmaVault.deposit.selector);
        if (!_isCapitalFlowPreHook(hook)) {
            revert HyperCorePreHooksNotWired(PlasmaVault.deposit.selector, hook);
        }
        _requireFlowsWiredTo(hook);
    }

    function _requireFlowsWiredTo(address hook_) private view {
        _requireWired(PlasmaVault.deposit.selector, hook_);
        _requireWired(PlasmaVault.depositWithPermit.selector, hook_);
        _requireWired(PlasmaVault.mint.selector, hook_);
        _requireWired(PlasmaVault.withdraw.selector, hook_);
        _requireWired(PlasmaVault.redeem.selector, hook_);
        _requireWired(PlasmaVault.redeemFromRequest.selector, hook_);
    }

    function _requireWired(bytes4 selector_, address hook_) private view {
        address implementation = PreHooksLib.getPreHookImplementation(selector_);
        if (implementation != hook_) {
            revert HyperCorePreHooksNotWired(selector_, implementation);
        }
    }

    function _isCapitalFlowPreHook(address hook_) private view returns (bool) {
        if (hook_.code.length == 0) {
            return false;
        }
        (bool ok, bytes memory ret) = hook_.staticcall(abi.encodeWithSignature("HYPERCORE_CAPITAL_FLOW_PRE_HOOK_ID()"));
        return ok && ret.length == 32 && abi.decode(ret, (bytes32)) == CAPITAL_FLOW_PRE_HOOK_ID;
    }
}

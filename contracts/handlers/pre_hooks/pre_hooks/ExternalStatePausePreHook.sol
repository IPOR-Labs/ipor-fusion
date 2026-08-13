// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPreHook} from "../IPreHook.sol";
import {IExternalStateExecutor} from "../../../fuses/external_state/IExternalStateExecutor.sol";
import {ExternalStateErrors} from "../../../fuses/external_state/errors/ExternalStateErrors.sol";
import {ExternalStateExecutorStorageLib} from "../../../fuses/external_state/lib/ExternalStateExecutorStorageLib.sol";

/// @title ExternalStatePausePreHook
/// @notice Pre-execution hook that blocks user-facing vault operations when the ExternalState pause flag is set,
///         when an unprocessed big-change event is detected on the executor, or when at least one
///         balance account has grown too stale.
/// @dev Runs via delegatecall from PlasmaVault. Read-only with respect to storage (no state writes).
///      The inline big-change check closes the window between a custodian confirm and the next
///      `balanceOf()` call — without it, a user could deposit/withdraw at inflated NAV before the
///      balance fuse has a chance to set the pause flag.
///      Register this hook against the selectors for deposit / mint / depositWithPermit / withdraw / redeem
///      via `PlasmaVaultGovernance.setPreHookImplementations` (see contracts/fuses/external_state/README.md).
/// @author IPOR Labs
contract ExternalStatePausePreHook is IPreHook {
    /// @notice Market identifier bound to this pre-hook instance (documentation / governance wiring only).
    uint256 public immutable MARKET_ID;

    /// @param marketId_ Market identifier this pre-hook is associated with.
    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    /// @notice Executes pause + inline big-change + staleness checks before the gated user operation runs.
    /// @dev `selector_` is intentionally ignored — the same checks apply to every gated selector.
    ///
    ///      **Revert-code transition after an unprocessed custodian update.** The inline big-change
    ///      branch is stateless: it compares `executor.lastCustodianUpdateTimestamp` against
    ///      `ExternalStateExecutorStorageLib.getLastCheckedCustodianTimestamp()` but does **not** advance the
    ///      latter. Only `ExternalStateBalanceFuse.balanceOf` writes `lastCheckedCustodianTimestamp` (and sets
    ///      the pause flag). Sequence during a big-change event:
    ///        1. Custodian confirm lands at T0 → executor.lastCustodianUpdateTimestamp = T0.
    ///        2. User op hits this pre-hook before any `balanceOf` read → reverts
    ///           `ExternalStatePreHookBigChangeDetected(prevTotal, currentTotal, bigChangeBps)`.
    ///        3. Repeat user ops keep reverting with the same error (stateless re-evaluation).
    ///        4. Keeper / alpha triggers `_updateMarketsBalances` → `ExternalStateBalanceFuse.balanceOf` sets
    ///           `paused = true` and writes `lastCheckedCustodianTimestamp = T0`.
    ///        5. Subsequent user ops revert with `ExternalStatePreHookPaused` instead.
    ///      Both revert codes represent the same fail-closed outcome (user blocked); the code switch
    ///      is expected and not a bug. Operators triaging alerts should treat either error as "ExternalState
    ///      market gated — atomist unpause required after off-chain review". See `README.md`
    ///      ("Pre-hook gating") for the operator flow.
    /// @param selector_ The function selector that triggered this pre-hook (unused, retained for IPreHook compliance).
    // solhint-disable-next-line no-unused-vars
    function run(bytes4 selector_) external override {
        selector_; // silence unused-var warning while keeping the NatSpec-friendly signature style used by peers.
        address executor = ExternalStateExecutorStorageLib.getExecutor();
        if (executor == address(0)) revert ExternalStateErrors.ExternalStatePreHookExecutorNotDeployed();

        if (ExternalStateExecutorStorageLib.getPaused()) revert ExternalStateErrors.ExternalStatePreHookPaused();

        // Inline big-change detection: if the executor has received a new custodian update that
        // the balance fuse has not yet processed, check the delta here so user ops are blocked
        // immediately (without waiting for the next balanceOf() call).
        (uint256 totalBalance, uint256 bigChangeBps, uint256 lastCustodianTs) =
            IExternalStateExecutor(executor).getBalanceFuseSnapshot();
        uint256 lastChecked = ExternalStateExecutorStorageLib.getLastCheckedCustodianTimestamp();

        if (lastCustodianTs != lastChecked) {
            uint256 prevTotal = ExternalStateExecutorStorageLib.getLastTotalBalance();
            if (prevTotal != 0 && bigChangeBps != 0) {
                uint256 delta = totalBalance > prevTotal ? totalBalance - prevTotal : prevTotal - totalBalance;
                if ((delta * 10_000) / prevTotal > bigChangeBps) {
                    revert ExternalStateErrors.ExternalStatePreHookBigChangeDetected(prevTotal, totalBalance, bigChangeBps);
                }
            }
        }

        uint256 oldest = IExternalStateExecutor(executor).getOldestUpdateTimestamp();
        if (oldest != 0) {
            uint256 max = IExternalStateExecutor(executor).stalenessMax();
            if (block.timestamp - oldest > max) {
                revert ExternalStateErrors.ExternalStatePreHookStale(oldest, block.timestamp, max);
            }
        }
    }
}

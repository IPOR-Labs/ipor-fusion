// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IExternalStateExecutor} from "../IExternalStateExecutor.sol";
import {ExternalStateExecutorStorageLib} from "./ExternalStateExecutorStorageLib.sol";

/// @title ExternalStateBigChangeLib
/// @notice Settles a pending custodian update (big-change circuit breaker) in the PlasmaVault delegatecall context.
/// @dev Called by `ExternalStateBalanceFuse.balanceOf` and, BEFORE any ALPHA flow, by
///      `ExternalStateOperationFuse.enter` / `exit`, so that the `lastTotalBalance` baseline is always the state after
///      the last custodian confirm and a delta never contains ALPHA's own enter/exit (IL-8775).
///      The state lives in the single per-vault ERC-7201 slot of `ExternalStateExecutorStorageLib` (not keyed by
///      market id); only one ExternalState market per vault is supported, so there is a single watermark per vault.
///      The events below repeat the signatures declared on `ExternalStateBalanceFuse` (identical topic0).
/// @author IPOR Labs
library ExternalStateBigChangeLib {
    /// @notice Emitted when a big-change event triggers the pause flag.
    /// @param previousTotal Previously observed total balance.
    /// @param newTotal Newly observed total balance.
    /// @param thresholdBps Configured big-change threshold in basis points.
    event ExternalStateBigChangeDetected(uint256 previousTotal, uint256 newTotal, uint256 thresholdBps);

    /// @notice Emitted when the confirm-count watermark advances after observing a new custodian update.
    /// @param oldConfirmCount Previously stored snapshot confirm count.
    /// @param newConfirmCount New snapshot confirm count.
    event ExternalStateBalanceFuseLastCustodianConfirmCountUpdated(uint256 oldConfirmCount, uint256 newConfirmCount);

    /// @notice Emitted when a changed `lastTotalBalance` snapshot is persisted.
    /// @param oldTotalBalance Previously stored total balance (underlying units).
    /// @param newTotalBalance New total balance (underlying units).
    event ExternalStateBalanceFuseLastTotalBalanceUpdated(uint256 oldTotalBalance, uint256 newTotalBalance);

    /// @notice Read the executor snapshot, run the big-change check when a new custodian update was observed and
    ///         persist the watermark and `lastTotalBalance`.
    /// @dev The executor call is a view on executor storage (no callback into the vault, IL-7895).
    /// @param executor_ Deployed executor address (non-zero).
    /// @return totalBalance Total tracked balance in underlying units as reported by the executor.
    function processCustodianUpdate(address executor_) internal returns (uint256 totalBalance) {
        uint256 bigChangeBps;
        uint256 custodianConfirmCount;
        (totalBalance, bigChangeBps, custodianConfirmCount) = IExternalStateExecutor(executor_)
            .getBalanceFuseSnapshot();

        uint256 lastChecked = ExternalStateExecutorStorageLib.getLastCheckedCustodianConfirmCount();
        uint256 prevTotal = ExternalStateExecutorStorageLib.getLastTotalBalance();

        // Big-change check ONLY when a new custodian update has been observed. `custodianConfirmCount`
        // is a strictly monotonic per-confirmation counter (not a timestamp), so two confirms landing
        // in the same block are still distinguishable here (IL-7969 fix).
        if (custodianConfirmCount != lastChecked) {
            // First custodian update establishes the baseline and does not trigger a pause
            // (prevTotal == 0 corresponds to the "alpha-only" pre-custodian period).
            if (prevTotal != 0 && bigChangeBps != 0) {
                uint256 delta = totalBalance > prevTotal ? totalBalance - prevTotal : prevTotal - totalBalance;
                if ((delta * 10_000) / prevTotal > bigChangeBps) {
                    ExternalStateExecutorStorageLib.setPaused(true);
                    emit ExternalStateBigChangeDetected(prevTotal, totalBalance, bigChangeBps);
                }
            }
            emit ExternalStateBalanceFuseLastCustodianConfirmCountUpdated(lastChecked, custodianConfirmCount);
            ExternalStateExecutorStorageLib.setLastCheckedCustodianConfirmCount(custodianConfirmCount);
        }

        if (totalBalance != prevTotal) {
            emit ExternalStateBalanceFuseLastTotalBalanceUpdated(prevTotal, totalBalance);
            ExternalStateExecutorStorageLib.setLastTotalBalance(totalBalance);
        }
    }
}

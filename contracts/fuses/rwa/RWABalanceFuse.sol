// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";

import {IRWAExecutor} from "./IRWAExecutor.sol";
import {RWAErrors} from "./errors/RWAErrors.sol";
import {RWAExecutorStorageLib} from "./lib/RWAExecutorStorageLib.sol";

/// @title RWABalanceFuse
/// @notice Balance fuse for the RWA market. Reports the total underlying balance tracked by the
///         executor converted to USD WAD, and detects "big-change" events on custodian updates
///         to set the vault-scoped pause flag.
/// @dev Not a view function: writes `lastTotalBalance`, `lastCheckedCustodianTimestamp`, and the
///      pause flag into ERC-7201 vault storage. Runs via delegatecall from PlasmaVault.
/// @author IPOR Labs
contract RWABalanceFuse is IMarketBalanceFuse, IFuseCommon {
    /// @notice Deployment address captured at construction.
    address public immutable VERSION;

    /// @notice Market identifier bound to this fuse instance.
    uint256 public immutable override MARKET_ID;

    /// @notice Emitted when a big-change event triggers the pause flag.
    /// @param previousTotal Previously observed total balance.
    /// @param newTotal Newly observed total balance.
    /// @param thresholdBps Configured big-change threshold in basis points.
    event RWABigChangeDetected(uint256 previousTotal, uint256 newTotal, uint256 thresholdBps);

    /// @notice Emitted when the balance fuse advances its `lastCheckedCustodianTimestamp` snapshot
    ///         after observing a new custodian update.
    /// @param oldTimestamp Previously stored snapshot timestamp.
    /// @param newTimestamp New snapshot timestamp (matches `lastCustodianUpdateTimestamp` from the executor).
    event RWABalanceFuseLastCustodianTimestampUpdated(uint256 oldTimestamp, uint256 newTimestamp);

    /// @notice Emitted when the balance fuse persists a changed `lastTotalBalance` snapshot.
    /// @dev Emitted only when the new value differs from the previous one to avoid spamming logs
    ///      on every NAV refresh.
    /// @param oldTotalBalance Previously stored total balance (underlying units).
    /// @param newTotalBalance New total balance (underlying units).
    event RWABalanceFuseLastTotalBalanceUpdated(uint256 oldTotalBalance, uint256 newTotalBalance);

    /// @param marketId_ Market identifier this balance fuse serves (must be non-zero).
    constructor(uint256 marketId_) {
        if (marketId_ == 0) revert RWAErrors.RWAZeroMarketId();
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Compute the current USD balance of the RWA market; side-effects big-change pausing.
    /// @dev **IMPORTANT — NOT a view function.** Despite the read-style name (dictated by the
    ///      `IMarketBalanceFuse` interface and shared across every balance fuse in this codebase),
    ///      `balanceOf()` MUTATES vault ERC-7201 storage on every call:
    ///      - `setLastTotalBalance(...)` records the latest observed total (snapshot for big-change detection),
    ///      - `setLastCheckedCustodianTimestamp(...)` advances the custodian timestamp watermark,
    ///      - `setPaused(true)` may flip the pause flag when a custodian update breaches `bigChangeBps`.
    ///      Renaming the function would require breaking changes throughout the PlasmaVault
    ///      balance-aggregation pipeline, so the convention is preserved.
    ///
    ///      **Security note (M-4):** the USD figure returned here is derived from
    ///      `PriceOracleMiddleware(underlying).getAssetPrice(...)` at call time. The same flash-loan
    ///      manipulation concerns apply as in `RWAOperationFuse._convertAmountToUnderlying` —
    ///      governance MUST bind only TWAP / Chainlink / Pyth-with-staleness feeds. See
    ///      `contracts/fuses/rwa/README.md` ("Oracle requirements").
    /// @return balanceValueUsd Balance in USD represented in 18 decimals (WAD).
    function balanceOf() external override returns (uint256 balanceValueUsd) {
        address executor = RWAExecutorStorageLib.getExecutor();
        if (executor == address(0)) {
            return 0;
        }

        (uint256 totalBalance, uint256 bigChangeBps, uint256 lastCustodianTs) = IRWAExecutor(executor).getBalanceFuseSnapshot();

        uint256 lastChecked = RWAExecutorStorageLib.getLastCheckedCustodianTimestamp();
        uint256 prevTotal = RWAExecutorStorageLib.getLastTotalBalance();

        // Big-change check ONLY when a new custodian update has been observed.
        if (lastCustodianTs != lastChecked) {
            // First custodian update establishes the baseline and does not trigger a pause
            // (prevTotal == 0 corresponds to the "alpha-only" pre-custodian period).
            if (prevTotal != 0 && bigChangeBps != 0) {
                uint256 delta = totalBalance > prevTotal ? totalBalance - prevTotal : prevTotal - totalBalance;
                if ((delta * 10_000) / prevTotal > bigChangeBps) {
                    RWAExecutorStorageLib.setPaused(true);
                    emit RWABigChangeDetected(prevTotal, totalBalance, bigChangeBps);
                }
            }
            emit RWABalanceFuseLastCustodianTimestampUpdated(lastChecked, lastCustodianTs);
            RWAExecutorStorageLib.setLastCheckedCustodianTimestamp(lastCustodianTs);
        }

        if (totalBalance != prevTotal) {
            emit RWABalanceFuseLastTotalBalanceUpdated(prevTotal, totalBalance);
            RWAExecutorStorageLib.setLastTotalBalance(totalBalance);
        }

        if (totalBalance == 0) {
            return 0;
        }

        address underlying = IERC4626(address(this)).asset();
        address oracle = PlasmaVaultLib.getPriceOracleMiddleware();
        if (oracle == address(0)) revert RWAErrors.RWAPriceOracleNotSet();

        (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(oracle).getAssetPrice(underlying);
        if (price == 0) revert RWAErrors.RWAInvalidPrice(underlying);

        uint256 underlyingDecimals = IERC20Metadata(underlying).decimals();
        balanceValueUsd = IporMath.convertToWad(totalBalance * price, underlyingDecimals + priceDecimals);
    }
}

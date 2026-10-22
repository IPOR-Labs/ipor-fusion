// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";

import {ExternalStateErrors} from "./errors/ExternalStateErrors.sol";
import {ExternalStateExecutorStorageLib} from "./lib/ExternalStateExecutorStorageLib.sol";
import {ExternalStateBigChangeLib} from "./lib/ExternalStateBigChangeLib.sol";

/// @title ExternalStateBalanceFuse
/// @notice Balance fuse for the ExternalState market. Reports the total underlying balance tracked by the
///         executor converted to USD WAD, and detects "big-change" events on custodian updates
///         to set the vault-scoped pause flag.
/// @dev Not a view function: writes `lastTotalBalance`, `lastCheckedCustodianConfirmCount`, and the
///      pause flag into ERC-7201 vault storage. Runs via delegatecall from PlasmaVault.
/// @author IPOR Labs
contract ExternalStateBalanceFuse is IMarketBalanceFuse, IFuseCommon {
    /// @notice Deployment address captured at construction.
    address public immutable VERSION;

    /// @notice Market identifier bound to this fuse instance.
    uint256 public immutable override MARKET_ID;

    /// @notice Emitted when a big-change event triggers the pause flag (emitted by `ExternalStateBigChangeLib`, same signature).
    /// @param previousTotal Previously observed total balance.
    /// @param newTotal Newly observed total balance.
    /// @param thresholdBps Configured big-change threshold in basis points.
    event ExternalStateBigChangeDetected(uint256 previousTotal, uint256 newTotal, uint256 thresholdBps);

    /// @notice Emitted (by `ExternalStateBigChangeLib`, from `balanceOf` and from OperationFuse `enter`/`exit`) when
    ///         the `lastCheckedCustodianConfirmCount` snapshot advances after a new custodian update.
    /// @param oldConfirmCount Previously stored snapshot confirm count.
    /// @param newConfirmCount New snapshot confirm count (matches `confirmCount` from the executor).
    event ExternalStateBalanceFuseLastCustodianConfirmCountUpdated(uint256 oldConfirmCount, uint256 newConfirmCount);

    /// @notice Emitted (by `ExternalStateBigChangeLib`) when a changed `lastTotalBalance` snapshot is persisted.
    /// @dev Emitted only when the new value differs from the previous one to avoid spamming logs
    ///      on every NAV refresh.
    /// @param oldTotalBalance Previously stored total balance (underlying units).
    /// @param newTotalBalance New total balance (underlying units).
    event ExternalStateBalanceFuseLastTotalBalanceUpdated(uint256 oldTotalBalance, uint256 newTotalBalance);

    /// @param marketId_ Market identifier this balance fuse serves (must be non-zero).
    constructor(uint256 marketId_) {
        if (marketId_ == 0) revert ExternalStateErrors.ExternalStateZeroMarketId();
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Compute the current USD balance of the ExternalState market; side-effects big-change pausing.
    /// @dev **IMPORTANT — NOT a view function.** Despite the read-style name (dictated by the
    ///      `IMarketBalanceFuse` interface and shared across every balance fuse in this codebase),
    ///      `balanceOf()` MUTATES vault ERC-7201 storage on every call:
    ///      - `setLastTotalBalance(...)` records the latest observed total (snapshot for big-change detection),
    ///      - `setLastCheckedCustodianConfirmCount(...)` advances the custodian confirm-count watermark,
    ///      - `setPaused(true)` may flip the pause flag when a custodian update breaches `bigChangeBps`.
    ///      The big-change logic lives in `ExternalStateBigChangeLib.processCustodianUpdate`, which
    ///      `ExternalStateOperationFuse.enter/exit` also run BEFORE ALPHA's flow, so this call normally only sees
    ///      custodian changes (IL-8775).
    ///      Renaming the function would require breaking changes throughout the PlasmaVault
    ///      balance-aggregation pipeline, so the convention is preserved.
    ///
    ///      **Security note (M-4):** the USD figure returned here is derived from
    ///      `PriceOracleMiddleware(underlying).getAssetPrice(...)` at call time. The same flash-loan
    ///      manipulation concerns apply as in `ExternalStateOperationFuse._convertAmountToUnderlying` —
    ///      governance MUST bind only TWAP / Chainlink / Pyth-with-staleness feeds. See
    ///      `contracts/fuses/external_state/README.md` ("Oracle requirements").
    /// @return balanceValueUsd Balance in USD represented in 18 decimals (WAD).
    function balanceOf() external override returns (uint256 balanceValueUsd) {
        address executor = ExternalStateExecutorStorageLib.getExecutor();
        if (executor == address(0)) {
            return 0;
        }

        // Settles a pending custodian update (big-change check + watermark + lastTotalBalance). The same call runs
        // before every ALPHA enter/exit, so a delta seen here never contains ALPHA's own flow (IL-8775).
        uint256 totalBalance = ExternalStateBigChangeLib.processCustodianUpdate(executor);

        if (totalBalance == 0) {
            return 0;
        }

        address underlying = IERC4626(address(this)).asset();
        address oracle = PlasmaVaultLib.getPriceOracleMiddleware();
        if (oracle == address(0)) revert ExternalStateErrors.ExternalStatePriceOracleNotSet();

        (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(oracle).getAssetPrice(underlying);
        if (price == 0) revert ExternalStateErrors.ExternalStateInvalidPrice(underlying);

        uint256 underlyingDecimals = IERC20Metadata(underlying).decimals();
        balanceValueUsd = IporMath.convertToWad(totalBalance * price, underlyingDecimals + priceDecimals);
    }
}

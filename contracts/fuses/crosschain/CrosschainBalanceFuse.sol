// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {ICrosschainExecutor} from "../../crosschain/interfaces/ICrosschainExecutor.sol";
import {CrosschainRecoveryLib} from "./lib/CrosschainRecoveryLib.sol";
import {
    CrosschainSubstrateLib,
    CrosschainSubstrate,
    CrosschainSubstrateType,
    IExecutorAssetView
} from "./lib/CrosschainSubstrateLib.sol";

/// @title CrosschainBalanceFuse
/// @notice Provides USD-denominated valuation of the crosschain NAV managed by the executor(s) whitelisted
///         to this vault's CROSSCHAIN market.
/// @dev Reads `getBalance()` (whatever the executor reports, in the EXECUTOR's `ASSET()` units: Stargate
///      idle + settled + both in-flight buckets, CCIP idle + settled + outbound in-flight transfers) from
///      every granted EXECUTOR substrate and converts each balance to USD via the price oracle
///      middleware and IporMath. An executor's asset MAY differ from the vault underlying, so every
///      executor is priced in its own asset (own price feed + own decimals) before summing. `getBalance()`
///      is fail-closed (reverts on staleness or on a blocked chain that still tracks value; on Stargate also
///      while a return record without a staleness slot is open, IL-8618), so a stale chain
///      propagates a revert into NAV updates by design, except in a recovery batch armed for that executor
///      (cached / unchecked fallback, see `balanceOf`).
/// @author IPOR Labs
contract CrosschainBalanceFuse is IMarketBalanceFuse {
    /// @notice Thrown when the price oracle middleware is not configured in the PlasmaVault.
    error CrosschainBalanceFuseInvalidPriceOracleMiddleware();

    /// @notice Thrown when a granted CROSSCHAIN substrate is not a valid EXECUTOR (wrong type or zero
    ///         address). NAV fails closed rather than silently skipping a malformed granted substrate (§9 P2).
    error CrosschainBalanceFuseInvalidExecutorSubstrate(uint8 substrateType, address substrateAddress);

    /// @notice Thrown when a granted executor's immutable MANAGER is not this PlasmaVault (§9 P2).
    error CrosschainBalanceFuseExecutorManagerMismatch(address executor, address manager);

    /// @notice Emitted when a cached market value is served instead of the live executor NAV.
    /// @dev The executor's `getBalance()` was fail-closed with `reason` (one of the allowlisted selectors
    ///      below) during a recovery batch armed for this executor, and the market holds a single executor. With
    ///      several executors the fuse emits `CrosschainUncheckedBalanceServed` instead.
    /// @param marketId Market whose balance is being valued.
    /// @param executor Executor whose `getBalance()` reverted.
    /// @param reason Selector of the executor's fail-closed revert.
    event CrosschainCachedBalanceServed(uint256 marketId, address executor, bytes4 reason);
    /// @notice Emitted when, in a market with several executors, one recovery-marked executor is valued by its
    ///         booked `getBalanceUnchecked()` because its `getBalance()` reverted with the staleness selector
    ///         `reason` (IL-8611). Never emitted for `ChainBlocked`: a blocked chain keeps the batch reverting.
    /// @param marketId Market whose balance is being valued.
    /// @param executor Executor valued by its `getBalanceUnchecked()`.
    /// @param reason Selector of the executor's staleness revert.
    event CrosschainUncheckedBalanceServed(uint256 marketId, address executor, bytes4 reason);
    /// @notice The recovered-USD correction EXCEEDED the cached market value, so the market was valued at zero
    ///         (IL-8598). The zero floor is kept on purpose. Not necessarily a contradiction: (a) the cache is lower
    ///         than what the executor actually held (e.g. funds came back with yield); (b) an executor whose
    ///         `ASSET()` differs from the vault underlying, whose price rose since the last refresh (price-basis
    ///         drift, IL-8597), so NAV moves towards the true value, never above it; (c) a genuine accounting
    ///         contradiction. Treat it as a signal to review, not automatically as an incident.
    /// @param marketId Market whose balance is being valued.
    /// @param cachedUsd Cached market value re-priced in USD (WAD).
    /// @param recoveredUsd Recovered-USD correction (WAD) that exceeded `cachedUsd`.
    event CrosschainRecoveredUsdClamped(uint256 marketId, uint256 cachedUsd, uint256 recoveredUsd);

    /// @dev Fail-closed reverts of the executors' `getBalance()` for which the cached fallback may be served.
    ///      `ChainBlocked(uint256)`: CCIP `CcipExecutorTransferLib.balanceByChain` and Stargate
    ///      `StargateExecutorAccountingLib.computeNavSD`.
    bytes4 internal constant CHAIN_BLOCKED = bytes4(keccak256("ChainBlocked(uint256)"));
    /// @dev `ObservationStale(uint256)`: CCIP `CcipExecutorTransferLib.balanceByChain` (settled bucket without
    ///      a fresh approved observation).
    bytes4 internal constant OBSERVATION_STALE = bytes4(keccak256("ObservationStale(uint256)"));
    /// @dev `TransferStale(uint256,uint256)`: CCIP `CcipExecutorTransferLib.balanceByChain` (stale pending
    ///      transfer, active return or cancelled unresolved recall, IL-8590).
    bytes4 internal constant TRANSFER_STALE = bytes4(keccak256("TransferStale(uint256,uint256)"));
    /// @dev `NavSettledStale(uint256)`: Stargate `StargateExecutorAccountingLib.computeNavSD` (settled bucket
    ///      without a fresh approved observation).
    bytes4 internal constant NAV_SETTLED_STALE = bytes4(keccak256("NavSettledStale(uint256)"));
    /// @dev `NavTransferStale(uint256)`: Stargate `StargateExecutorAccountingLib.computeNavSD` (stale oldest
    ///      unresolved transfer record or cancelled unresolved recall, IL-8621).
    bytes4 internal constant NAV_TRANSFER_STALE = bytes4(keccak256("NavTransferStale(uint256)"));

    /// @notice Identifier of the market this balance fuse is associated with.
    uint256 public immutable MARKET_ID;

    /// @param marketId_ Unique identifier of the market handled by this fuse.
    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    /// @notice Returns the USD value of the crosschain assets tracked by the granted executor(s).
    /// @return balanceValueUsd Balance expressed in 18-decimal USD precision (WAD format).
    /// @dev Prices each granted EXECUTOR's `getBalance()` in that executor's own `ASSET()` and sums the
    ///      USD-WAD values. Returns 0 when no executor is granted or every executor balance is zero.
    function balanceOf() external override returns (uint256 balanceValueUsd) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        uint256 len = substrates.length;

        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        // Counted up front, not inside the loop: the cache fallback below has to know whether this market
        // holds a sibling executor whose live value it would be discarding, and the failing executor may
        // be reached before the others have been seen.
        uint256 executorCount = _grantedExecutorCount(substrates, len);

        for (uint256 i; i < len; ++i) {
            CrosschainSubstrate memory substrate = CrosschainSubstrateLib.bytes32ToSubstrate(substrates[i]);
            // REMOTE_VAULT substrates whitelist command-fuse targets on other chains — they carry no
            // locally readable balance, so they are not part of NAV.
            if (substrate.substrateType == CrosschainSubstrateType.REMOTE_VAULT) {
                continue;
            }
            // Fail closed on any malformed granted substrate rather than silently skipping it: a wrong
            // type or zero address is a misconfiguration, not "no exposure" (§9 P2). Zero substrates is
            // still zero NAV: the loop simply does not run.
            if (substrate.substrateType != CrosschainSubstrateType.EXECUTOR || substrate.substrateAddress == address(0))
            {
                revert CrosschainBalanceFuseInvalidExecutorSubstrate(
                    uint8(substrate.substrateType), substrate.substrateAddress
                );
            }
            address executor = substrate.substrateAddress;
            // Every summed executor must have code and be managed by THIS vault — otherwise its NAV would
            // be attributed wrongly. Its asset may differ from the vault underlying: it is priced below
            // with its own feed and decimals.
            if (executor.code.length == 0) {
                revert CrosschainSubstrateLib.CrosschainFuseExecutorNoCode(executor);
            }
            address manager = ICrosschainExecutor(executor).MANAGER();
            if (manager != address(this)) revert CrosschainBalanceFuseExecutorManagerMismatch(executor, manager);

            uint256 balanceInExecutorAsset;
            try ICrosschainExecutor(executor).getBalance() returns (uint256 liveBalance) {
                balanceInExecutorAsset = liveBalance;
            } catch (bytes memory reason) {
                // Recovery actions must not be rolled back merely because the same condition they are
                // repairing still keeps live NAV fail-closed. Serve the last cached market value (single
                // executor) or this executor's booked balance (several executors, below); ordinary paths
                // never set the transient recovery marker and rethrow.
                //
                // Two conditions, both required. The marker must have been armed for THIS executor —
                // otherwise a recovery on one transport would swallow a fail-closed revert from a sibling
                // executor the batch never touched and is not repairing. Second, the revert must be one of
                // the executors' documented fail-closed selectors. Anything
                // else is not a condition a recovery is repairing and must not be masked: a callee
                // out-of-gas (EIP-150 leaves this frame 1/64 of the gas and empty returndata, so ALPHA's
                // choice of the transaction gas limit would decide whether the cache is served), a
                // `Panic(uint256)` or `Error(string)` from the executor's accounting, or an unknown error
                // (IL-8564 / IL-8638). Those rethrow with the original returndata.
                // A future executor fail-closed error that is not in this allowlist will block recovery
                // batches until the fuse is updated (fail-safe direction by design).
                if (!CrosschainRecoveryLib.isRecovery(MARKET_ID, executor) || !_isFailClosedReason(reason)) {
                    assembly {
                        revert(add(reason, 0x20), mload(reason))
                    }
                }
                if (executorCount == 1) {
                    emit CrosschainCachedBalanceServed(MARKET_ID, executor, bytes4(reason));
                    return _cachedBalanceValueUsd(priceOracleMiddleware);
                }
                // With several executors only a STALENESS reason may be substituted. `ChainBlocked` means the
                // executor's books are known-inconsistent until a rescue completes (e.g.
                // `DROP_RETURN_METADATA_INCLUDED` credits `idleLedger` while `settledRemoteBalance` still holds
                // the same value), so serving its booked balance would double count and persist the phantom
                // value as the market's NAV (IL-8611 follow-up). Rethrow with the original returndata: a vault-side
                // batch touching this market stays blocked until the rescue / force-set completes.
                if (bytes4(reason) == CHAIN_BLOCKED) {
                    assembly {
                        revert(add(reason, 0x20), mload(reason))
                    }
                }
                // Several executors (IL-8611 / TP-M-33): the market-wide cache cannot be decomposed per
                // executor — substituting it would discard the live value of every healthy sibling and persist
                // a pre-transaction snapshot as the market's NAV (audit
                // `cross_transport_recovery_marker_suppresses_fail_closed_gate_and_discards_sibling_executor_nav`).
                // So only THIS executor is substituted, by its booked balance without the staleness gates
                // (`getBalanceUnchecked`); every sibling keeps its own `getBalance()` verdict, and an unmarked
                // fail-closed sibling still reverts above. The unchecked value is the executor's current
                // booked state, so a value a recovery fuse already pulled out is not in it and needs no
                // `recoveredUsd` correction. `getBalanceUnchecked()` itself reverts `ChainBlocked` while a
                // blocked chain of the executor still tracks value (Stargate: also while a return record without a
                // staleness slot is open, IL-8618; a staleness selector can surface first), and that revert bubbles.
                emit CrosschainUncheckedBalanceServed(MARKET_ID, executor, bytes4(reason));
                balanceInExecutorAsset = ICrosschainExecutor(executor).getBalanceUnchecked();
            }
            if (balanceInExecutorAsset == 0) {
                continue;
            }

            if (priceOracleMiddleware == address(0)) {
                revert CrosschainBalanceFuseInvalidPriceOracleMiddleware();
            }

            address executorAsset = IExecutorAssetView(executor).ASSET();
            (uint256 price, uint256 priceDecimals) =
                IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(executorAsset);

            // Convert balance * price to WAD (18 decimals) accounting for both price and asset decimals.
            balanceValueUsd += IporMath.convertToWad(
                balanceInExecutorAsset * price, IERC20Metadata(executorAsset).decimals() + priceDecimals
            );
        }
    }

    /// @dev True when `reason_` starts with one of the executors' fail-closed `getBalance()` selectors.
    ///      Returndata shorter than 4 bytes (out-of-gas, empty revert) is never fail-closed.
    function _isFailClosedReason(bytes memory reason_) private pure returns (bool) {
        if (reason_.length < 4) return false;
        bytes4 selector = bytes4(reason_);
        return selector == CHAIN_BLOCKED || selector == OBSERVATION_STALE || selector == TRANSFER_STALE
            || selector == NAV_SETTLED_STALE || selector == NAV_TRANSFER_STALE;
    }

    /// @dev Number of granted EXECUTOR substrates on this market. It decodes every substrate with
    ///      `bytes32ToSubstrate`, which reverts `CrosschainFuseInvalidSubstrateType` on an out-of-range substrate
    ///      type, so a malformed substrate type fails here, before the main loop. Other malformed fields (in-range
    ///      UNDEFINED type, zero address, no code, foreign MANAGER) are not checked here; the main loop rejects
    ///      those. The executor asset is never checked: each executor is priced in its own `ASSET()`.
    function _grantedExecutorCount(bytes32[] memory substrates_, uint256 len_) private pure returns (uint256 count) {
        for (uint256 i; i < len_; ++i) {
            if (
                CrosschainSubstrateLib.bytes32ToSubstrate(substrates_[i]).substrateType
                    == CrosschainSubstrateType.EXECUTOR
            ) {
                ++count;
            }
        }
    }

    /// @dev Fallback used ONLY while a recovery action runs against fail-closed live NAV in a single-executor
    ///      market: preserve the last cached market value so the recovery is not rolled back by the very
    ///      condition it repairs.
    ///
    ///      The cache is a snapshot taken BEFORE this transaction, so any value a recovery fuse has
    ///      already pulled out of the market and into the vault's own balance is still inside it. Since
    ///      `PlasmaVault.totalAssets()` is `balanceOf(underlying) + Σ market values`, returning the raw
    ///      cache would count those assets twice — inflating share price and letting
    ///      `updateMarketsBalances` realize a phantom gain that mints performance fee shares. Subtract
    ///      what was withdrawn in-transaction (audit H-1).
    ///
    ///      The correction applies ONLY while the cache still contains the recovered value. Transient
    ///      storage lives for the whole transaction, but this cache is re-persisted at the end of every
    ///      `execute()` batch, so a later batch in the same transaction reads a cache from which the
    ///      recovery has already been removed. `isRecoveredUsdApplicable` detects exactly that — the
    ///      accumulator is ignored unless it was rebased against the cache being read now — which stops
    ///      the same recovery from being subtracted once per batch and persisted as an understated NAV.
    ///
    ///      Price bases (IL-8597, by design): the minuend re-prices the cache, built from the executor asset's price
    ///      at the last successful refresh, with the CURRENT underlying price, while the subtrahend was computed from
    ///      the CURRENT executor-asset price at claim time. For an executor whose `ASSET()` differs from the vault
    ///      underlying the two sit on different price bases, so each claim re-bases the remaining exposure. The
    ///      correction is NAV-neutral against the no-claim baseline (the claimed value leaves this market and is
    ///      re-priced in the vault's ERC20 balance market for that asset, which the vault MUST hold for every
    ///      non-underlying executor asset it can claim) and it keeps, rather than shrinks, the cache's price
    ///      staleness. If the correction exceeds the cached value the market is valued at zero and
    ///      `CrosschainRecoveredUsdClamped` is emitted (IL-8598); an exact full recovery also yields zero but emits
    ///      nothing.
    function _cachedBalanceValueUsd(address priceOracleMiddleware_) private returns (uint256) {
        if (priceOracleMiddleware_ == address(0)) revert CrosschainBalanceFuseInvalidPriceOracleMiddleware();
        address underlying = IERC4626(address(this)).asset();
        (uint256 price, uint256 priceDecimals) =
            IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(underlying);
        uint256 cachedUsd = IporMath.convertToWad(
            PlasmaVaultLib.getTotalAssetsInMarket(MARKET_ID) * price,
            IERC20Metadata(underlying).decimals() + priceDecimals
        );
        if (!CrosschainRecoveryLib.isRecoveredUsdApplicable(MARKET_ID)) {
            return cachedUsd;
        }
        uint256 recoveredUsd = CrosschainRecoveryLib.recoveredUsd(MARKET_ID);
        if (recoveredUsd > cachedUsd) {
            emit CrosschainRecoveredUsdClamped(MARKET_ID, cachedUsd, recoveredUsd);
            return 0;
        }
        return cachedUsd - recoveredUsd;
    }
}

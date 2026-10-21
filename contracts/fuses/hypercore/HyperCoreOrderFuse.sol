// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "../IFuseCommon.sol";
import {HyperCoreLib} from "./lib/HyperCoreLib.sol";
import {HyperCoreAssetIdLib} from "./lib/HyperCoreAssetIdLib.sol";
import {HyperCoreSupportedDexLib} from "./lib/HyperCoreSupportedDexLib.sol";
import {HyperCoreSubstrateLib} from "./lib/HyperCoreSubstrateLib.sol";
import {HyperCorePendingLib} from "./lib/HyperCorePendingLib.sol";
import {HyperCoreHookWiringLib} from "./lib/HyperCoreHookWiringLib.sol";

/// @dev Data structure for entering the HyperCore limit order fuse (action 1, perp only)
struct HyperCoreOrderFuseEnterData {
    /// @notice HyperCore perp asset index
    uint32 asset;
    /// @notice true for buy/long, false for sell/short
    bool isBuy;
    /// @notice Limit price, 1e8 fixed point
    uint64 limitPx;
    /// @notice Order size, 1e8 fixed point
    uint64 sz;
    /// @notice Whether the order is restricted to reduce an existing position
    bool reduceOnly;
    /// @notice Time in force: 1 = ALO, 2 = GTC, 3 = IOC
    uint8 tif;
    /// @notice Client order id, must be non-zero
    uint128 cloid;
}

/// @title HyperCoreOrderFuse
/// @author IPOR Labs
/// @notice Places a perp limit order on HyperCore (CoreWriter action 1). Spot pairs are out of scope.
/// @dev Executes in PlasmaVault storage context via delegatecall. MUST NOT contain storage variables.
///      Orders always settle TIMING-style (IL-8527/IL-8543): no pending record, only a one-order-per-Core-L1-block
///      rate limit (`recordTimingOrder`). The legacy `Config{SettlementMode}` / `Config{WindowOrderSeconds}` keys
///      are ignored.
contract HyperCoreOrderFuse is IFuseCommon {
    /// @notice The address of the version of the Fuse
    address public immutable VERSION;
    /// @notice The Market ID associated with the Fuse
    uint256 public immutable MARKET_ID;

    /// @notice Emitted when entering the HyperCore order fuse
    event HyperCoreOrderFuseEnter(
        address version,
        uint32 asset,
        bool isBuy,
        uint64 limitPx,
        uint64 sz,
        bool reduceOnly,
        uint8 tif,
        uint128 cloid
    );

    /// @notice Thrown when the market ID passed to the constructor is zero
    error HyperCoreOrderFuseInvalidMarketId();

    /// @notice Thrown when the vault's HyperCore account does not exist yet
    error HyperCoreOrderFuseAccountNotActivated();

    /// @notice Thrown when the perp asset is not granted as a PerpMarket substrate
    error HyperCoreOrderFuseMarketNotGranted(uint32 asset);

    /// @notice Thrown when the action asset belongs to an unsupported perp dex.
    error HyperCoreOrderFuseUnsupportedPerpDex(uint32 dex);

    /// @notice Thrown when the action asset dex is not enabled by this market.
    error HyperCoreOrderFusePerpDexNotConfigured(uint32 dex);

    /// @notice Thrown when a HIP-3 market grant requires a single matching PerpMarket substrate.
    error HyperCoreOrderFuseSingleMarketRequired(uint256 count);

    /// @notice Thrown when `tif` is not one of ALO/GTC/IOC
    error HyperCoreOrderFuseInvalidTif(uint8 tif);

    /// @notice Thrown when `cloid` is zero
    error HyperCoreOrderFuseCloidRequired();

    /// @notice Thrown when `sz` or `limitPx` is zero
    error HyperCoreOrderFuseZeroAmount();

    /// @notice Thrown when `sz` is not a multiple of the asset's lot size
    error HyperCoreOrderFuseInvalidLot(uint64 sz, uint64 lot);

    /// @notice Thrown when the order notional exceeds the granted cap. The admission price is `limitPx` for buys
    ///         and `max(limitPx, markPx)` for sells, because a sell's limit is only a price floor.
    error HyperCoreOrderFuseExceedsMaxNotional(uint256 notionalUsd6, uint88 maxNotionalUsd6);

    /// @notice Thrown when an order that increases the vault's absolute position in `asset` would leave it with a
    ///         notional above the granted `PerpPositionCap` (IL-8534). Notional is valued at the order's admission
    ///         price (see `HyperCoreOrderFuseExceedsMaxNotional`) and assumes a full fill.
    error HyperCoreOrderFusePositionCapExceeded(uint32 asset, uint256 positionNotionalUsd6, uint256 capUsd6);

    /// @notice Thrown when a sell order is admitted while the market's mark price reads zero (fail closed)
    error HyperCoreOrderFuseMarkPriceUnavailable(uint32 readIndex);

    /// @notice Thrown when the grant requires reduce-only but the order did not set it
    error HyperCoreOrderFuseReduceOnlyRequired();

    /// @notice Constructor for HyperCoreOrderFuse
    /// @param marketId_ The Market ID associated with the Fuse
    constructor(uint256 marketId_) {
        if (marketId_ == 0) {
            revert HyperCoreOrderFuseInvalidMarketId();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Places a perp limit order on HyperCore
    /// @param data_ Enter data describing the order
    /// @dev @custom:revert HyperCorePreHooksNotWired When the order is not reduce-only and the six share-priced
    ///      selectors are not all wired to one HyperCoreCapitalFlowPreHook (IL-8529)
    function enter(HyperCoreOrderFuseEnterData memory data_) public {
        _validate(data_);

        HyperCorePendingLib.requireOrderRateLimit();

        bytes memory payload = HyperCoreLib.encodeLimitOrder(
            data_.asset,
            data_.isBuy,
            data_.limitPx,
            data_.sz,
            data_.reduceOnly,
            data_.tif,
            data_.cloid
        );
        HyperCoreLib.sendRawAction(payload);

        // Orders move no value across domains: no pending record, only the one-Core-block mini-gate.
        HyperCorePendingLib.recordTimingOrder();

        emit HyperCoreOrderFuseEnter(
            VERSION,
            data_.asset,
            data_.isBuy,
            data_.limitPx,
            data_.sz,
            data_.reduceOnly,
            data_.tif,
            data_.cloid
        );
    }

    /// @dev Runs all pre-send checks for `enter`.
    ///      Factored out of `enter` to keep its stack shallow (Solidity "stack too deep" without via-ir).
    /// @dev @custom:revert HyperCorePreHooksNotWired When the order is not reduce-only and the CapitalFlow pre-hook
    ///      wiring check fails (IL-8529)
    function _validate(HyperCoreOrderFuseEnterData memory data_) internal view {
        HyperCorePendingLib.requireNotPendingAction();

        if (!HyperCoreLib.coreUserExists(address(this))) {
            revert HyperCoreOrderFuseAccountNotActivated();
        }

        (bool granted, uint88 maxNotionalUsd6, bool reduceOnlyRequired) = HyperCoreSubstrateLib.getPerpMarket(
            MARKET_ID,
            data_.asset
        );
        if (!granted) {
            revert HyperCoreOrderFuseMarketNotGranted(data_.asset);
        }

        _validatePerpAssetAndSingleMarket(data_.asset);

        if (
            data_.tif != HyperCoreLib.TIF_ALO && data_.tif != HyperCoreLib.TIF_GTC && data_.tif != HyperCoreLib.TIF_IOC
        ) {
            revert HyperCoreOrderFuseInvalidTif(data_.tif);
        }

        if (data_.cloid == 0) {
            revert HyperCoreOrderFuseCloidRequired();
        }

        if (data_.sz == 0 || data_.limitPx == 0) {
            revert HyperCoreOrderFuseZeroAmount();
        }

        _validateLotAndNotional(data_.asset, data_.isBuy, data_.sz, data_.limitPx, maxNotionalUsd6);

        if (reduceOnlyRequired && !data_.reduceOnly) {
            revert HyperCoreOrderFuseReduceOnlyRequired();
        }

        // IL-8529: opening risk requires the CapitalFlow wiring; reduce-only orders stay allowed (de-risking).
        if (!data_.reduceOnly) {
            HyperCoreHookWiringLib.requireCapitalFlowWired();
        }

        _validatePositionCap(data_);
    }

    /// @dev IL-8534 aggregate position cap. A no-op when no `PerpPositionCap` is granted for the asset (only the
    ///      per-order cap applies). Otherwise assumes a full fill: post-order size is `szi + sz` (buy) or
    ///      `szi - sz` (sell), with `sz` converted from the 1e8 order scale to the position's `szDecimals` units.
    ///      An order that keeps or reduces |size| is always allowed, so de-risking is never blocked, even above the
    ///      cap. Resting GTC orders are invisible on-chain and are not counted.
    function _validatePositionCap(HyperCoreOrderFuseEnterData memory data_) internal view {
        (bool capSet, uint88 capUsd6) = HyperCoreSubstrateLib.getPerpPositionCap(MARKET_ID, data_.asset);
        if (!capSet) {
            return;
        }

        uint32 readIndex = HyperCoreAssetIdLib.readIndexOf(data_.asset);
        uint8 szDecimals = HyperCoreLib.perpAssetInfo(readIndex).szDecimals;
        int256 szi = HyperCoreAssetIdLib.isNativePerpAsset(data_.asset)
            ? HyperCoreLib.position(address(this), readIndex).szi
            : HyperCoreLib.position2(address(this), readIndex).szi;

        // `sz` is a multiple of the lot (checked earlier), so the division is exact.
        int256 delta = int256(uint256(data_.sz / HyperCoreLib.lotOf(szDecimals)));
        int256 post = data_.isBuy ? szi + delta : szi - delta;
        uint256 postAbs = post < 0 ? uint256(-post) : uint256(post);
        uint256 preAbs = szi < 0 ? uint256(-szi) : uint256(szi);
        if (postAbs <= preAbs) {
            return;
        }

        uint256 px1e8 = _admissionPx1e8(readIndex, data_.isBuy, data_.limitPx, szDecimals);
        uint256 size1e8 = postAbs * uint256(HyperCoreLib.lotOf(szDecimals));
        uint256 notionalUsd6 = (size1e8 * px1e8 + 1e10 - 1) / 1e10;
        if (notionalUsd6 > capUsd6) {
            revert HyperCoreOrderFusePositionCapExceeded(data_.asset, notionalUsd6, capUsd6);
        }
    }

    /// @dev Checks that the order's dex is enabled and applies the HIP-3 single-market admission rule.
    function _validatePerpAssetAndSingleMarket(uint32 asset_) internal view {
        uint32 dex = HyperCoreAssetIdLib.perpDexOf(asset_);
        if (!HyperCoreSupportedDexLib.isSupportedPerpDex(dex)) {
            revert HyperCoreOrderFuseUnsupportedPerpDex(dex);
        }
        if (!HyperCoreSubstrateLib.isPerpDexConfigured(MARKET_ID, dex)) {
            revert HyperCoreOrderFusePerpDexNotConfigured(dex);
        }

        (uint256 marketCount, bool hasHip3, uint32 soleAsset) = HyperCoreSubstrateLib.getPerpMarketStats(MARKET_ID);
        if (hasHip3 && (marketCount != 1 || soleAsset != asset_)) {
            revert HyperCoreOrderFuseSingleMarketRequired(marketCount);
        }
    }

    /// @dev Split out to further reduce `_validate`'s stack usage. Sells are admitted at
    ///      `max(limitPx, markPx)`: a sell limit is a price floor, so a crossing sell fills at the (higher)
    ///      bid and `sz * limitPx` would understate the executable notional.
    function _validateLotAndNotional(
        uint32 asset_,
        bool isBuy_,
        uint64 sz_,
        uint64 limitPx_,
        uint88 maxNotionalUsd6_
    ) internal view {
        uint32 readIndex = HyperCoreAssetIdLib.readIndexOf(asset_);
        HyperCoreLib.PerpAssetInfo memory info = HyperCoreLib.perpAssetInfo(readIndex);
        uint64 lot = HyperCoreLib.lotOf(info.szDecimals);
        if (sz_ % lot != 0) {
            revert HyperCoreOrderFuseInvalidLot(sz_, lot);
        }

        uint256 notionalUsd6 = HyperCoreLib.orderNotionalUsd6(
            sz_,
            _admissionPx1e8(readIndex, isBuy_, limitPx_, info.szDecimals)
        );
        if (notionalUsd6 > maxNotionalUsd6_) {
            revert HyperCoreOrderFuseExceedsMaxNotional(notionalUsd6, maxNotionalUsd6_);
        }
    }

    /// @dev Price used for the notional cap. Buys: `limitPx` (a buy never fills above it). Sells: the greater
    ///      of `limitPx` and the current mark price in the same 1e8 scale; a zero mark price fails closed.
    function _admissionPx1e8(
        uint32 readIndex_,
        bool isBuy_,
        uint64 limitPx_,
        uint8 szDecimals_
    ) internal view returns (uint256) {
        if (isBuy_) {
            return limitPx_;
        }
        uint256 markPx1e8 = HyperCoreLib.markPx1e8(readIndex_, szDecimals_);
        if (markPx1e8 == 0) {
            revert HyperCoreOrderFuseMarkPriceUnavailable(readIndex_);
        }
        return markPx1e8 > limitPx_ ? markPx1e8 : uint256(limitPx_);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPriceOracleMiddleware} from "../../../price_oracle/IPriceOracleMiddleware.sol";
import {Errors} from "../../../libraries/errors/Errors.sol";
import {IporMath} from "../../../libraries/math/IporMath.sol";
import {PlasmaVaultLib} from "../../../libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../../libraries/PlasmaVaultConfigLib.sol";
import {HyperCoreAssetIdLib} from "./HyperCoreAssetIdLib.sol";
import {HyperCoreLib} from "./HyperCoreLib.sol";
import {HyperCoreSupportedDexLib} from "./HyperCoreSupportedDexLib.sol";
import {HyperCoreSubstrateLib} from "./HyperCoreSubstrateLib.sol";

/// @notice Reads the vault's live standard-mode HyperCore spot, native-perp and HIP-3 perp NAV.
/// @dev Called through a vault delegatecall. Never includes an EVM-side balance. The set of HIP-3
///      (builder-deployed) perp dexes valued here is whatever the vault's `PerpDexIds` config
///      substrate enables; each enabled dex contributes its full `accountMarginSummary` equity.
library HyperCoreValuationLib {
    error HyperCoreNegativeBalance(int256 balance);
    error HyperCorePriceOverflow(uint64 tokenIndex);

    /// @dev Default `MaxNavJumpBps` (50%) when the config substrate is not granted.
    uint256 internal constant DEFAULT_MAX_NAV_JUMP_BPS = 5000;

    /// @notice The live Core value deviates from the stored market value by more than the allowed bps.
    error HyperCoreNavJumpExceeded(uint256 storedWad, uint256 liveWad, uint256 maxJumpBps);
    /// @notice The configured `MaxNavJumpBps` is zero or exceeds `type(uint64).max`, or the configured
    ///         `NavJumpFloorUsd6` exceeds `type(uint64).max` (overflow guards).
    error HyperCoreNavJumpConfigInvalid(uint240 value);
    /// @notice The underlying asset has no oracle price, so the stored value cannot be compared.
    error HyperCoreNavJumpReferenceUnavailable();

    /// @dev Default `MaxMarkOracleDeviationBps` (5%) when the config substrate is not granted.
    uint256 internal constant DEFAULT_MAX_MARK_ORACLE_DEVIATION_BPS = 500;

    /// @notice A held perp market's mark price deviates from the Core oracle price by more than the allowed bps
    ///         (or the oracle price reads zero). Prices are the raw precompile values of the market's read index.
    error HyperCoreMarkOracleDeviation(uint32 asset, uint64 markPx, uint64 oraclePx);
    /// @notice The configured `MaxMarkOracleDeviationBps` is zero or exceeds `type(uint64).max` (overflow guard).
    error HyperCoreMarkOracleBandConfigInvalid(uint240 value);

    /// @notice Live Core NAV in USD WAD, guarded by the NAV jump circuit breaker (IL-8533).
    /// @dev Reverts when the live value differs from the value stored for `marketId` (priced in USD WAD
    ///      through the vault oracle) by more than `MaxNavJumpBps` AND by more than the absolute `NavJumpFloorUsd6` tolerance
    ///      (default 0 = no tolerance). The comparison is skipped while the stored value is zero
    ///      (first activation / fully withdrawn); a zero or above-`uint64` `MaxNavJumpBps` always reverts.
    function liveValueWad(uint256 marketId) internal view returns (uint256 live) {
        live = _rawLiveValueWad(marketId);
        _checkNavJump(marketId, live);
    }

    function _checkNavJump(uint256 marketId, uint256 live) private view {
        (bool set, uint240 configured) = HyperCoreSubstrateLib.getConfig(
            marketId,
            HyperCoreSubstrateLib.ConfigKey.MaxNavJumpBps
        );
        if (set && (configured == 0 || configured > type(uint64).max)) {
            revert HyperCoreNavJumpConfigInvalid(configured);
        }
        (bool floorSet, uint240 floorUsd6) = HyperCoreSubstrateLib.getConfig(
            marketId,
            HyperCoreSubstrateLib.ConfigKey.NavJumpFloorUsd6
        );
        if (floorSet && floorUsd6 > type(uint64).max) {
            revert HyperCoreNavJumpConfigInvalid(floorUsd6);
        }
        uint256 stored = PlasmaVaultLib.getTotalAssetsInMarket(marketId);
        if (stored == 0) {
            return;
        }
        uint256 maxJumpBps = set ? uint256(configured) : DEFAULT_MAX_NAV_JUMP_BPS;

        address underlying = IERC4626(address(this)).asset();
        (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(PlasmaVaultLib.getPriceOracleMiddleware())
            .getAssetPrice(underlying);
        if (price == 0) {
            revert HyperCoreNavJumpReferenceUnavailable();
        }
        uint256 storedWad = IporMath.convertToWad(
            stored * price,
            uint256(IERC20Metadata(underlying).decimals()) + priceDecimals
        );
        uint256 diff = live > storedWad ? live - storedWad : storedWad - live;
        // IL-8766: absolute tolerance. A deviation up to `NavJumpFloorUsd6` never trips the relative check, so a
        // small donation to a small stored value cannot freeze the vault. Unset = 0 = purely relative breaker.
        uint256 floorWad = floorSet ? uint256(floorUsd6) * 1e12 : 0;
        if (diff > floorWad && diff * 10_000 > maxJumpBps * storedWad) {
            revert HyperCoreNavJumpExceeded(storedWad, live, maxJumpBps);
        }
    }

    /// @notice IL-8534 mark-vs-Core-oracle band for share-priced flows (called by the capital-flow pre-hook only;
    ///         valuation, refreshes and manager actions do not check it, so the manager can de-risk while prices diverge).
    /// @dev Validates the `PerpDexIds` config first, then no-ops while the vault has no Core account.
    ///      Reverts with `HyperCoreMarkOracleDeviation` / `HyperCoreMarkOracleBandConfigInvalid`.
    function checkMarkOracleBand(uint256 marketId) internal view {
        uint240 perpDexBitmap = HyperCoreSubstrateLib.getPerpDexBitmap(marketId);
        if (!HyperCoreLib.coreUserExists(address(this))) {
            return;
        }
        _checkMarkOracleBand(marketId, perpDexBitmap);
    }

    /// @dev IL-8534 mark-vs-oracle band. For every granted PerpMarket substrate on which the vault holds a non-zero
    ///      position, requires `|markPx - oraclePx| * 10_000 <= maxBps * oraclePx` (same raw scale, read index).
    ///      Markets without a position are skipped after the single position read. HIP-3 markets are only read when
    ///      their dex is enabled in `bitmap_` (the same dexes NAV values). Assets outside the native/HIP-3 id space
    ///      are ignored. Native markets use position 0x800, HIP-3 markets 0x813 (read index above 65535 possible).
    function _checkMarkOracleBand(uint256 marketId, uint240 bitmap_) private view {
        (bool set, uint240 configured) = HyperCoreSubstrateLib.getConfig(
            marketId,
            HyperCoreSubstrateLib.ConfigKey.MaxMarkOracleDeviationBps
        );
        if (set && (configured == 0 || configured > type(uint64).max)) {
            revert HyperCoreMarkOracleBandConfigInvalid(configured);
        }
        uint256 maxBps = set ? uint256(configured) : DEFAULT_MAX_MARK_ORACLE_DEVIATION_BPS;

        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId);
        for (uint256 i; i < substrates.length; ++i) {
            if (HyperCoreSubstrateLib.substrateType(substrates[i]) != HyperCoreSubstrateLib.SubstrateType.PerpMarket) {
                continue;
            }
            (uint32 asset, , ) = HyperCoreSubstrateLib.decodePerpMarket(substrates[i]);
            _checkAssetBand(asset, bitmap_, maxBps);
        }
    }

    function _checkAssetBand(uint32 asset_, uint240 bitmap_, uint256 maxBps_) private view {
        int64 szi;
        uint32 readIndex;
        if (HyperCoreAssetIdLib.isNativePerpAsset(asset_)) {
            readIndex = asset_;
            szi = HyperCoreLib.position(address(this), readIndex).szi;
        } else if (HyperCoreAssetIdLib.isHip3Asset(asset_)) {
            if (bitmap_ & (uint240(1) << HyperCoreAssetIdLib.perpDexOf(asset_)) == 0) {
                return;
            }
            readIndex = HyperCoreAssetIdLib.readIndexOf(asset_);
            szi = HyperCoreLib.position2(address(this), readIndex).szi;
        } else {
            return;
        }
        if (szi == 0) {
            return;
        }

        uint64 mark = HyperCoreLib.markPx(readIndex);
        uint64 oracle = HyperCoreLib.oraclePx(readIndex);
        uint256 diff = mark > oracle ? uint256(mark) - oracle : uint256(oracle) - mark;
        if (oracle == 0 || diff * 10_000 > maxBps_ * uint256(oracle)) {
            revert HyperCoreMarkOracleDeviation(asset_, mark, oracle);
        }
    }

    function _rawLiveValueWad(uint256 marketId) private view returns (uint256) {
        // Validate the configured HIP-3 dex bitmap before any other read, including the
        // unactivated-account short-circuit below.
        uint240 perpDexBitmap = HyperCoreSubstrateLib.getPerpDexBitmap(marketId);

        // A newly deployed vault has no Core account until its first EVM→Core deposit.
        if (!HyperCoreLib.coreUserExists(address(this))) {
            return 0;
        }

        (uint64[] memory tokenIndexes, address[] memory evmAssets) = HyperCoreSubstrateLib.getSpotTokens(marketId);
        address oracle = PlasmaVaultLib.getPriceOracleMiddleware();
        int256 value;

        for (uint256 i; i < tokenIndexes.length; ++i) {
            uint64 tokenIndex = tokenIndexes[i];
            HyperCoreLib.SpotBalance memory balance = HyperCoreLib.spotBalance(address(this), tokenIndex);
            if (balance.total == 0) {
                continue;
            }

            HyperCoreLib.TokenInfo memory token = HyperCoreLib.tokenInfo(tokenIndex);
            (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(oracle).getAssetPrice(evmAssets[i]);
            if (price == 0) {
                revert Errors.UnsupportedQuoteCurrencyFromOracle();
            }
            if (price > uint256(type(int256).max) / balance.total) {
                revert HyperCorePriceOverflow(tokenIndex);
            }
            value += IporMath.convertToWadInt(
                int256(uint256(balance.total) * price),
                uint256(token.weiDecimals) + priceDecimals
            );
        }

        // Native perp DEX 0 accountValue already contains margin, PnL, funding and fees.
        // It is signed; do not cast to uint before adding the spot leg.
        HyperCoreLib.AccountMarginSummary memory margin = HyperCoreLib.accountMarginSummary(
            HyperCoreLib.NATIVE_PERP_DEX,
            address(this)
        );
        value += IporMath.convertToWadInt(int256(margin.accountValue), 6);

        value += _hip3ValueWad(perpDexBitmap);

        if (value < 0) {
            revert HyperCoreNegativeBalance(value);
        }
        return uint256(value);
    }

    /// @notice Sums `accountMarginSummary(dex, vault).accountValue` for every HIP-3 dex enabled in
    ///         `bitmap_`, in the fixed order XYZ, ABCD, PARA, MKTS, IO. A dex whose bit is clear is
    ///         never read, to avoid an extra `0x80F` staticcall.
    function _hip3ValueWad(uint240 bitmap_) private view returns (int256 value) {
        if (bitmap_ & (uint240(1) << HyperCoreSupportedDexLib.XYZ_PERP_DEX) != 0) {
            value += _dexValueWad(HyperCoreSupportedDexLib.XYZ_PERP_DEX);
        }
        if (bitmap_ & (uint240(1) << HyperCoreSupportedDexLib.ABCD_PERP_DEX) != 0) {
            value += _dexValueWad(HyperCoreSupportedDexLib.ABCD_PERP_DEX);
        }
        if (bitmap_ & (uint240(1) << HyperCoreSupportedDexLib.PARA_PERP_DEX) != 0) {
            value += _dexValueWad(HyperCoreSupportedDexLib.PARA_PERP_DEX);
        }
        if (bitmap_ & (uint240(1) << HyperCoreSupportedDexLib.MKTS_PERP_DEX) != 0) {
            value += _dexValueWad(HyperCoreSupportedDexLib.MKTS_PERP_DEX);
        }
        if (bitmap_ & (uint240(1) << HyperCoreSupportedDexLib.IO_PERP_DEX) != 0) {
            value += _dexValueWad(HyperCoreSupportedDexLib.IO_PERP_DEX);
        }
    }

    function _dexValueWad(uint32 dex_) private view returns (int256) {
        HyperCoreLib.AccountMarginSummary memory summary = HyperCoreLib.accountMarginSummary(dex_, address(this));
        return IporMath.convertToWadInt(int256(summary.accountValue), 6);
    }
}

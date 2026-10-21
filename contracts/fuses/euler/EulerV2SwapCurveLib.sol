// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IEulerV2Swap} from "./ext/IEulerV2Swap.sol";

/// @title EulerV2SwapCurveLib
/// @notice Shared curve sanity guard for EulerV2SwapDeployFuse and EulerV2SwapReconfigureFuse.
/// @dev priceX/priceY is the marginal rate at the equilibrium point in asset1 base units per asset0
///      base unit (EulerSwap CurveLib.f). It is compared, decimals-normalised, against the vault's
///      PriceOracleMiddleware. The initial reserves must sit exactly at the equilibrium point so the
///      instantaneous rate at (re)activation equals priceX/priceY.
library EulerV2SwapCurveLib {
    uint256 internal constant WAD = 1e18;

    /// @notice Thrown when priceX/priceY deviates from the oracle ratio by more than the allowed band
    error EulerV2SwapCurvePriceOutOfBounds(uint256 curveToOracleRatioWad, uint256 maxDeviationWad);
    /// @notice Thrown when the initial virtual reserves are not the equilibrium reserves
    error EulerV2SwapInitialStateNotAtEquilibrium(
        uint112 reserve0,
        uint112 reserve1,
        uint112 equilibriumReserve0,
        uint112 equilibriumReserve1
    );
    /// @notice Thrown when the oracle returns a zero price for a pool asset
    error EulerV2SwapUnsupportedOraclePrice(address asset);
    /// @notice Thrown by the fuse constructors when the deviation band exceeds 100% (1e18)
    error EulerV2SwapPriceDeviationTooHigh(uint256 priceDeviationWad);

    /// @notice Reverts unless the curve is priced within `maxDeviationWad_` of the oracle and the
    ///         initial reserves are the equilibrium reserves.
    /// @param supplyVault0_ eVault whose asset() is asset0 (same derivation as EulerSwap.getAssets)
    /// @param supplyVault1_ eVault whose asset() is asset1
    function requireCurveAtOraclePrice(
        address supplyVault0_,
        address supplyVault1_,
        IEulerV2Swap.DynamicParams memory dynamicParams_,
        IEulerV2Swap.InitialState memory initialState_,
        uint256 maxDeviationWad_
    ) internal view {
        if (
            initialState_.reserve0 != dynamicParams_.equilibriumReserve0 ||
            initialState_.reserve1 != dynamicParams_.equilibriumReserve1
        ) {
            revert EulerV2SwapInitialStateNotAtEquilibrium(
                initialState_.reserve0,
                initialState_.reserve1,
                dynamicParams_.equilibriumReserve0,
                dynamicParams_.equilibriumReserve1
            );
        }

        if (dynamicParams_.priceX == 0 || dynamicParams_.priceY == 0) {
            revert EulerV2SwapCurvePriceOutOfBounds(0, maxDeviationWad_);
        }

        address asset0 = ERC4626(supplyVault0_).asset();
        address asset1 = ERC4626(supplyVault1_).asset();

        // Split into a helper (fewer live locals per call frame) to avoid "stack too deep": this repo
        // forbids via_ir, so the mulDiv expression below cannot share a frame with the price fetches.
        uint256 curveToOracleRatioWad = _curveToOracleRatioWad(
            asset0,
            asset1,
            dynamicParams_.priceX,
            dynamicParams_.priceY
        );

        if (curveToOracleRatioWad < WAD - maxDeviationWad_ || curveToOracleRatioWad > WAD + maxDeviationWad_) {
            revert EulerV2SwapCurvePriceOutOfBounds(curveToOracleRatioWad, maxDeviationWad_);
        }
    }

    /// @dev curveToOracleRatioWad = (priceX / priceY) / oracleRatio, in WAD, where oracleRatio is the
    ///      oracle-implied ratio in base units: (price0 / 10^dec0) / (price1 / 10^dec1).
    function _curveToOracleRatioWad(
        address asset0_,
        address asset1_,
        uint80 priceX_,
        uint80 priceY_
    ) private view returns (uint256) {
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();
        uint256 price0Wad = _assetPriceWad(priceOracleMiddleware, asset0_);
        uint256 price1Wad = _assetPriceWad(priceOracleMiddleware, asset1_);

        return
            Math.mulDiv(
                uint256(priceX_) * price1Wad * 10 ** IERC20Metadata(asset0_).decimals(),
                WAD,
                uint256(priceY_) * price0Wad * 10 ** IERC20Metadata(asset1_).decimals()
            );
    }

    /// @dev Reverts with the named error instead of surfacing a division-by-zero Panic downstream.
    function _assetPriceWad(address priceOracleMiddleware_, address asset_) private view returns (uint256) {
        (uint256 price, uint256 decimals) = IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(asset_);
        if (price == 0) {
            revert EulerV2SwapUnsupportedOraclePrice(asset_);
        }
        return IporMath.convertToWad(price, decimals);
    }
}

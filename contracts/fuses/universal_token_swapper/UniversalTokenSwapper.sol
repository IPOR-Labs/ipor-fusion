// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {SwapExecutor, SwapExecutorData} from "./SwapExecutor.sol";

struct UniversalTokenSwapperData {
    address[] dexs;
    bytes[] dexData;
}

struct UniversalTokenSwapperEnterData {
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    UniversalTokenSwapperData data;
}

contract UniversalTokenSwapperFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    event UniversalTokenSwapperEnterFuse(address version, address asset, uint256 amount);

    error UniversalTokenSwapperFuseUnsupportedAsset(address asset);
    error UniversalTokenSwapperFuseSlippageFail();

    address public immutable VERSION;
    address public immutable EXECUTOR;
    uint256 public immutable MARKET_ID;
    /// @dev slippageReverse in WAD decimals, 1e18 - slippage;
    uint256 public immutable SLIPPAGE_REVERSE;

    constructor(uint256 marketId_, address executor_, uint256 slippageReverse_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        EXECUTOR = executor_;
        SLIPPAGE_REVERSE = slippageReverse_;
    }

    function _enter(UniversalTokenSwapperEnterData calldata data_) internal {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.tokenIn)) {
            revert UniversalTokenSwapperFuseUnsupportedAsset(data_.tokenIn);
        }
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.tokenOut)) {
            revert UniversalTokenSwapperFuseUnsupportedAsset(data_.tokenOut);
        }
        uint256 dexsLength = data_.data.dexs.length;
        for (uint256 i; i < dexsLength; ++i) {
            if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.data.dexs[i])) {
                revert UniversalTokenSwapperFuseUnsupportedAsset(data_.data.dexs[i]);
            }
        }

        uint256 tokenInBalanceBefore = ERC20(data_.tokenIn).balanceOf(EXECUTOR);
        uint256 tokenOutBalanceBefore = ERC20(data_.tokenOut).balanceOf(EXECUTOR);

        ERC20(data_.tokenIn).safeTransfer(EXECUTOR, data_.amountIn);

        SwapExecutor(EXECUTOR).execute(
            SwapExecutorData({
                tokenIn: data_.tokenIn,
                tokenOut: data_.tokenOut,
                dexs: data_.data.dexs,
                dexsData: data_.data.dexData
            })
        );

        uint256 tokenInBalanceAfter = ERC20(data_.tokenIn).balanceOf(EXECUTOR);
        uint256 tokenOutBalanceAfter = ERC20(data_.tokenOut).balanceOf(EXECUTOR);

        if (tokenInBalanceAfter >= tokenInBalanceBefore) {
            return;
        }

        uint256 tokenInDelta = tokenInBalanceBefore - tokenInBalanceAfter;

        if (tokenOutBalanceAfter <= tokenOutBalanceBefore) {
            revert UniversalTokenSwapperFuseSlippageFail();
        }

        uint256 tokenOutDelta = tokenOutBalanceAfter - tokenOutBalanceBefore;

        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();
        (uint256 tokenInPrice, uint256 tokenInPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware)
            .getAssetPrice(data_.tokenIn);
        (uint256 tokenOutPrice, uint256 tokenOutPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware)
            .getAssetPrice(data_.tokenOut);

        uint256 amountUsdInDelta = IporMath.convertToWad(
            tokenInDelta * tokenInPrice,
            IERC20Metadata(data_.tokenIn).decimals() + tokenInPriceDecimals
        );
        uint256 amountUsdOutDelta = IporMath.convertToWad(
            tokenOutDelta * tokenOutPrice,
            IERC20Metadata(data_.tokenOut).decimals() + tokenOutPriceDecimals
        );

        uint256 quotient = IporMath.division(amountUsdInDelta * 1e18, amountUsdOutDelta);
        if (quotient <= SLIPPAGE_REVERSE) {
            revert UniversalTokenSwapperFuseSlippageFail();
        }
    }
}

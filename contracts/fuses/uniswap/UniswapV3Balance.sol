// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";

import {INonfungiblePositionManager, IUniswapV3Factory, IUniswapV3Pool} from "./ext/INonfungiblePositionManager.sol";

struct TempMemory {
    uint96 nonce;
    address operator;
    uint128 tokensOwed0;
    uint128 tokensOwed1;
    address token0Address;
    address token1Address;
    uint24 fee;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint256 feeGrowthInside0LastX128;
    uint256 feeGrowthInside1LastX128;
    uint256 feeGrowthGlobal0X128;
    uint256 feeGrowthGlobal1X128;
    uint256 token0FeesOwed;
    uint256 token1FeesOwed;
    uint256 balance;
    uint256 priceToken;
    uint256 priceDecimals;
    address priceOracleMiddleware;
    uint256 len;
}

contract UniswapV3Balance is IMarketBalanceFuse {
    uint256 public immutable MARKET_ID;
    address public immutable NONFUNGIBLE_POSITION_MANAGER;
    address public immutable UNISWAP_FACTORY;

    constructor(uint256 marketId_, address nonfungiblePositionManager_, address uniswapFactory_) {
        MARKET_ID = marketId_;
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
        UNISWAP_FACTORY = uniswapFactory_;
    }

    function balanceOf() external view override returns (uint256) {
        TempMemory memory tempMemory;
        uint256[] memory tokenIds = FuseStorageLib.getTokenIdUsedFuse().tokenIds;
        //        tempMemory.len = tokenIds.length;

        //        if (tempMemory.len == 0) {
        //            return 0;
        //        }

        tempMemory.priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        for (uint256 i; i < tokenIds.length; ++i) {
            (
                tempMemory.nonce,
                tempMemory.operator,
                tempMemory.token0Address,
                tempMemory.token1Address,
                tempMemory.fee,
                tempMemory.tickLower,
                tempMemory.tickUpper,
                tempMemory.liquidity,
                tempMemory.feeGrowthInside0LastX128,
                tempMemory.feeGrowthInside1LastX128,
                tempMemory.tokensOwed0,
                tempMemory.tokensOwed1
            ) = INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER).positions(tokenIds[i]);

            //            (tempMemory.feeGrowthGlobal0X128, tempMemory.feeGrowthGlobal1X128) = _getCurrentFeeGrowth(
            //                tempMemory.token0Address,
            //                tempMemory.token1Address,
            //                tempMemory.fee,
            //                tempMemory.tickLower,
            //                tempMemory.tickUpper
            //            );
            //
            //            tempMemory.token0FeesOwed =
            //                (tempMemory.liquidity * (tempMemory.feeGrowthGlobal0X128 - tempMemory.feeGrowthInside0LastX128)) /
            //                2 ** 128; //TODO check this
            //            tempMemory.token1FeesOwed =
            //                (tempMemory.liquidity * (tempMemory.feeGrowthGlobal1X128 - tempMemory.feeGrowthInside1LastX128)) /
            //                2 ** 128;
            //
            //            (tempMemory.priceToken, tempMemory.priceDecimals) = IPriceOracleMiddleware(tempMemory.priceOracleMiddleware)
            //                .getAssetPrice(tempMemory.token0Address);
            //
            //            tempMemory.balance += IporMath.convertToWad(
            //                (tempMemory.token0FeesOwed + tempMemory.tokensOwed0) * tempMemory.priceToken,
            //                IERC20Metadata(tempMemory.token0Address).decimals() + tempMemory.priceDecimals
            //            );
            //
            //            (tempMemory.priceToken, tempMemory.priceDecimals) = IPriceOracleMiddleware(tempMemory.priceOracleMiddleware)
            //                .getAssetPrice(tempMemory.token1Address);
            //            tempMemory.balance += IporMath.convertToWad(
            //                (tempMemory.token1FeesOwed + tempMemory.tokensOwed1) * tempMemory.priceToken,
            //                IERC20Metadata(tempMemory.token1Address).decimals() + tempMemory.priceDecimals
            //            );
        }

        //        return tempMemory.balance;
        return 0;
    }

    function _getCurrentFeeGrowth(
        address token0_,
        address token1_,
        uint24 fee_,
        int24 tickLower_,
        int24 tickUpper_
    ) private view returns (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) {
        address pool = IUniswapV3Factory(UNISWAP_FACTORY).getPool(token0_, token1_, fee_);
        require(pool != address(0), "Pool does not exist");

        IUniswapV3Pool uniswapPool = IUniswapV3Pool(pool);

        feeGrowthGlobal0X128 = uniswapPool.feeGrowthGlobal0X128();
        feeGrowthGlobal1X128 = uniswapPool.feeGrowthGlobal1X128();
    }
}

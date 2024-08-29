// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";

import {INonfungiblePositionManager, IUniswapV3Factory, IUniswapV3Pool} from "./ext/INonfungiblePositionManager.sol";

struct Position2 {
    address token0;
    address token1;
    uint24 fee;
    int24 tickLower;
    int24 tickUpper;
    uint128 liquidity;
    uint256 feeGrowthInside0LastX128;
    uint256 feeGrowthInside1LastX128;
    uint128 tokensOwed0;
    uint128 tokensOwed1;
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
        address priceOracleMiddleware;
        uint256 balance;
        uint256[] memory tokenIds = FuseStorageLib.getTokenIdUsedFuse().tokenIds;
        uint256 len = tokenIds.length;

        if (len == 0) {
            return 0;
        }

        priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        Position2 memory position;

        for (uint256 i = 0; i < len; i++) {
            position = extractData(tokenIds[0]);

            (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) = _getCurrentFeeGrowth(
                position.token0,
                position.token1,
                position.fee
            );

            uint256 token0FeesOwed = (position.liquidity * (feeGrowthGlobal0X128 - position.feeGrowthInside0LastX128)) /
                2 ** 128; //TODO check this
            uint256 token1FeesOwed = (position.liquidity * (feeGrowthGlobal1X128 - position.feeGrowthInside1LastX128)) /
                2 ** 128; //TODO check this

            (uint256 priceToken, uint256 priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(
                position.token0
            );

            balance += IporMath.convertToWad(
                (token0FeesOwed + position.tokensOwed0) * priceToken,
                IERC20Metadata(position.token0).decimals() + priceDecimals
            );

            (priceToken, priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(position.token1);
            balance += IporMath.convertToWad(
                (token1FeesOwed + position.tokensOwed1) * priceToken,
                IERC20Metadata(position.token1).decimals() + priceDecimals
            );
        }

        return balance;
    }

    function extractData(uint256 tokenId) private view returns (Position2 memory position) {
        (
            ,
            ,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER).positions(tokenId);
        position.token0 = token0;
        position.token1 = token1;
        position.fee = fee;
        position.tickLower = tickLower;
        position.tickUpper = tickUpper;
        position.liquidity = liquidity;
        position.feeGrowthInside0LastX128 = feeGrowthInside0LastX128;
        position.feeGrowthInside1LastX128 = feeGrowthInside1LastX128;
        position.tokensOwed0 = tokensOwed0;
        position.tokensOwed1 = tokensOwed1;
    }

    function _getCurrentFeeGrowth(
        address token0_,
        address token1_,
        uint24 fee_
    ) private view returns (uint256 feeGrowthGlobal0X128, uint256 feeGrowthGlobal1X128) {
        address pool = IUniswapV3Factory(UNISWAP_FACTORY).getPool(token0_, token1_, fee_);
        require(pool != address(0), "Pool does not exist");

        IUniswapV3Pool uniswapPool = IUniswapV3Pool(pool);

        feeGrowthGlobal0X128 = uniswapPool.feeGrowthGlobal0X128();
        feeGrowthGlobal1X128 = uniswapPool.feeGrowthGlobal1X128();
    }
}

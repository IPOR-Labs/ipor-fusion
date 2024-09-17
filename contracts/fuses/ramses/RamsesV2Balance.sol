// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {TickMath} from "./ext/TickMath.sol";
import {LiquidityAmounts} from "./ext/LiquidityAmounts.sol";
import {PoolAddress} from "./ext/PoolAddress.sol";

import {INonfungiblePositionManagerRamses, IRamsesV2Pool} from "./ext/INonfungiblePositionManagerRamses.sol";
import {PositionKey} from "./ext/PositionKey.sol";

/// @title Fuse balance for Ramses V2 positions.
contract RamsesV2Balance is IMarketBalanceFuse {
    bytes32 internal constant POOL_INIT_CODE_HASH = 0x1565b129f2d1790f12d45301b9b084335626f0c92410bc43130763b69971135d;

    uint256 public immutable MARKET_ID;
    /// @dev Manage NFTs representing liquidity positions
    address public immutable NONFUNGIBLE_POSITION_MANAGER;
    address public immutable RAMSES_FACTORY;

    constructor(uint256 marketId_, address nonfungiblePositionManager_, address ramsesFactory_) {
        MARKET_ID = marketId_;
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
        RAMSES_FACTORY = ramsesFactory_;
    }

    function balanceOf() external view override returns (uint256) {
        uint256[] memory tokenIds = FuseStorageLib.getRamsesV2TokenIds().tokenIds;
        uint256 len = tokenIds.length;

        if (len == 0) {
            return 0;
        }

        address priceOracleMiddleware;
        uint256 balance;
        address token0;
        address token1;
        uint256 amount0;
        uint256 amount1;
        uint256 priceToken;
        uint256 priceDecimals;

        priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        for (uint256 i; i < len; ++i) {
            /// @dev Calculation of amount for token0 and token1 in existing position, take into account the fees
            /// and principal that a given nonfungible position manager token is worth
            (token0, token1, amount0, amount1) = getAmountsForPosition(tokenIds[i]);

            (priceToken, priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(token0);

            balance += IporMath.convertToWad((amount0) * priceToken, IERC20Metadata(token0).decimals() + priceDecimals);

            (priceToken, priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(token1);
            balance += IporMath.convertToWad((amount1) * priceToken, IERC20Metadata(token1).decimals() + priceDecimals);
        }

        return balance;
    }

    function getAmountsForPosition(
        uint256 tokenId
    ) internal view returns (address token0t, address token1t, uint256 amount0, uint256 amount1) {
        INonfungiblePositionManagerRamses.Position memory position = getPositionData(tokenId);

        IRamsesV2Pool pool = IRamsesV2Pool(
            PoolAddress.computeAddress(
                RAMSES_FACTORY,
                PoolAddress.getPoolKey(position.token0, position.token1, position.fee)
            )
        );

        (uint160 sqrtPriceX96, , , , , , ) = pool.slot0();

        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(position.tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(position.tickUpper);

        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            sqrtRatioAX96,
            sqrtRatioBX96,
            position.liquidity
        );

        (uint256 fee0, uint256 fee1) = calculateFees(
            position.feeGrowthInside0Last,
            position.feeGrowthInside1Last,
            position.liquidity,
            tokenId,
            position.tickLower,
            position.tickUpper,
            pool
        );

        amount0 += (fee0 + position.tokensOwed0);
        amount1 += (fee1 + position.tokensOwed1);
        token0t = position.token0;
        token1t = position.token1;
    }

    function calculateFees(
        uint256 feeGrowthInside0Last,
        uint256 feeGrowthInside1Last,
        uint256 liquidity,
        uint256 tokenId,
        int24 tickLower,
        int24 tickUpper,
        IRamsesV2Pool pool
    ) internal view returns (uint256 fee0, uint256 fee1) {
        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128, , , ) = pool.positions(
            PositionKey.compute(address(this), tokenId, tickLower, tickUpper)
        );

        uint256 feeGrowthInside0 = feeGrowthInside0Last > feeGrowthInside0LastX128
            ? 0
            : feeGrowthInside0LastX128 - feeGrowthInside0Last;
        uint256 feeGrowthInside1 = feeGrowthInside1Last > feeGrowthInside1LastX128
            ? 0
            : feeGrowthInside1LastX128 - feeGrowthInside1Last;
        fee0 = (liquidity * (feeGrowthInside0)) / (1 << 128);
        fee1 = (liquidity * (feeGrowthInside1)) / (1 << 128);
    }

    function getPositionData(
        uint256 tokenId
    ) internal view returns (INonfungiblePositionManagerRamses.Position memory position) {
        (
            ,
            address operator,
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
        ) = INonfungiblePositionManagerRamses(NONFUNGIBLE_POSITION_MANAGER).positions(tokenId);
        position.operator = operator;
        position.token0 = token0;
        position.token1 = token1;
        position.fee = fee;
        position.tickLower = tickLower;
        position.tickUpper = tickUpper;
        position.liquidity = liquidity;
        position.feeGrowthInside0Last = feeGrowthInside0LastX128;
        position.feeGrowthInside1Last = feeGrowthInside1LastX128;
        position.tokensOwed0 = tokensOwed0;
        position.tokensOwed1 = tokensOwed1;
        return position;
    }
}

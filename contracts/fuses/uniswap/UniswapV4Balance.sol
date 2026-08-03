// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";

import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPositionManagerV4} from "./ext/v4/IPositionManagerV4.sol";
import {LiquidityAmountsV4} from "./ext/v4/LiquidityAmountsV4.sol";
import {PositionInfoLib} from "./ext/v4/PositionInfoLib.sol";

/**
 * @title UniswapV4Balance
 * @notice Fuse balance for Uniswap V4 positions
 * @dev Calculates the total USD value (WAD, 18 decimals) of all Uniswap V4 liquidity positions tracked
 *      in fuse storage. For each position the principal is derived from the pool's current sqrtPriceX96
 *      (StateLibrary.getSlot0) and the position's liquidity, and the pending (uncollected) fees are
 *      derived from fee growth deltas. In V4 there is no PositionValue.total() equivalent, so the value
 *      is composed from core reads. Note: at the PoolManager level the position owner is the
 *      PositionManager itself and positions are distinguished by salt = bytes32(tokenId).
 * @author IPOR Labs
 */
contract UniswapV4Balance is IMarketBalanceFuse {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error UniswapV4BalanceInvalidAddress();
    error UniswapV4BalanceInvalidPriceOracleMiddleware();
    /// @notice Address of this fuse contract version
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    uint256 public immutable MARKET_ID;

    /// @notice Uniswap V4 PositionManager (periphery) contract address
    address public immutable POSITION_MANAGER;

    /// @notice Uniswap V4 PoolManager (singleton core) contract
    IPoolManager public immutable POOL_MANAGER;

    /**
     * @notice Initializes the UniswapV4Balance fuse with market ID and protocol addresses
     * @param marketId_ The market ID used to identify the market
     * @param positionManager_ The address of the Uniswap V4 PositionManager
     * @param poolManager_ The address of the Uniswap V4 PoolManager
     */
    constructor(uint256 marketId_, address positionManager_, address poolManager_) {
        if (positionManager_ == address(0) || poolManager_ == address(0)) {
            revert UniswapV4BalanceInvalidAddress();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        POSITION_MANAGER = positionManager_;
        POOL_MANAGER = IPoolManager(poolManager_);
    }

    /**
     * @notice Calculates the total assets in the market for Uniswap V4 positions
     * @dev For each tracked tokenId: principal (from current pool price and position liquidity) plus
     *      pending fees (from fee growth deltas), both converted to USD via the price oracle middleware.
     * @return balance The total balance of assets in the market, normalized to WAD (18 decimals)
     */
    function balanceOf() external view override returns (uint256) {
        uint256[] memory tokenIds = FuseStorageLib.getUniswapV4TokenIds().tokenIds;
        uint256 len = tokenIds.length;

        if (len == 0) {
            return 0;
        }

        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();
        
        if(priceOracleMiddleware == address(0)) {
            revert UniswapV4BalanceInvalidPriceOracleMiddleware();
            
        }
        uint256 balance;

        for (uint256 i; i < len; ++i) {
            balance += _positionValueInUsd(priceOracleMiddleware, tokenIds[i]);
        }

        return balance;
    }

    function _positionValueInUsd(address priceOracleMiddleware_, uint256 tokenId_) private view returns (uint256) {
        (PoolKey memory poolKey, uint256 info) = IPositionManagerV4(POSITION_MANAGER).getPoolAndPositionInfo(tokenId_);

        uint128 liquidity = IPositionManagerV4(POSITION_MANAGER).getPositionLiquidity(tokenId_);

        uint256 amount0;
        uint256 amount1;

        /// @dev With zero liquidity there is neither principal nor further fee accrual; any previously
        /// accrued fees were realized during the decrease that brought liquidity to zero.
        if (liquidity > 0) {
            (amount0, amount1) = _principalAmounts(poolKey, info, liquidity);

            (uint256 fees0, uint256 fees1) = _pendingFees(poolKey.toId(), info, tokenId_, liquidity);

            amount0 += fees0;
            amount1 += fees1;
        }

        return
            _amountInUsd(priceOracleMiddleware_, Currency.unwrap(poolKey.currency0), amount0) +
            _amountInUsd(priceOracleMiddleware_, Currency.unwrap(poolKey.currency1), amount1);
    }

    function _principalAmounts(
        PoolKey memory poolKey_,
        uint256 info_,
        uint128 liquidity_
    ) private view returns (uint256 amount0, uint256 amount1) {
        (uint160 sqrtPriceX96, , , ) = POOL_MANAGER.getSlot0(poolKey_.toId());

        (amount0, amount1) = LiquidityAmountsV4.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(PositionInfoLib.tickLower(info_)),
            TickMath.getSqrtPriceAtTick(PositionInfoLib.tickUpper(info_)),
            liquidity_
        );
    }

    function _pendingFees(
        PoolId poolId_,
        uint256 info_,
        uint256 tokenId_,
        uint128 liquidity_
    ) private view returns (uint256 fees0, uint256 fees1) {
        int24 tickLower = PositionInfoLib.tickLower(info_);
        int24 tickUpper = PositionInfoLib.tickUpper(info_);

        /// @dev At the core level the position owner is the PositionManager, salt = bytes32(tokenId)
        (, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) = POOL_MANAGER.getPositionInfo(
            poolId_,
            POSITION_MANAGER,
            tickLower,
            tickUpper,
            bytes32(tokenId_)
        );

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = POOL_MANAGER.getFeeGrowthInside(
            poolId_,
            tickLower,
            tickUpper
        );

        /// @dev Fee growth deltas use wraparound-safe (unchecked) subtraction, matching core behavior
        unchecked {
            fees0 = FullMath.mulDiv(feeGrowthInside0X128 - feeGrowthInside0LastX128, liquidity_, FixedPoint128.Q128);
            fees1 = FullMath.mulDiv(feeGrowthInside1X128 - feeGrowthInside1LastX128, liquidity_, FixedPoint128.Q128);
        }
    }

    function _amountInUsd(
        address priceOracleMiddleware_,
        address token_,
        uint256 amount_
    ) private view returns (uint256) {
        if (amount_ == 0) {
            return 0;
        }

        (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(token_);

        return IporMath.convertToWad(amount_ * price, IERC20Metadata(token_).decimals() + priceDecimals);
    }
}

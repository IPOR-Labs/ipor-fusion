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
import {OracleSqrtPriceX96Lib} from "../../libraries/math/OracleSqrtPriceX96Lib.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPositionManagerV4} from "./ext/v4/IPositionManagerV4.sol";
import {LiquidityAmountsV4} from "./ext/v4/LiquidityAmountsV4.sol";
import {PositionInfoLib} from "./ext/v4/PositionInfoLib.sol";

/**
 * @title UniswapV4OracleBalance
 * @notice Balance fuse for Uniswap V4 positions that splits each position into token0/token1 at an
 *         oracle-implied price instead of the pool's spot price
 * @dev Oracle version of `UniswapV4Balance` for the same market (`UNISWAP_V4`, 53). It reads the same
 *      tokenId list (`FuseStorageLib.getUniswapV4TokenIds`), so an atomist switches a vault between the two
 *      versions with `addBalanceFuse(marketId, fuse)` without any storage migration. Both versions stay
 *      deployable; the atomist chooses one per vault.
 *
 *      Principal: the token0/token1 composition of every position is computed at the sqrt price derived
 *      from the `PriceOracleMiddleware` prices of the two pool currencies (`OracleSqrtPriceX96Lib.fromOracle`,
 *      the library used by the Slipstream balance fuses since IL-7959), never from `PoolManager` `slot0`.
 *      The pool spot price can be moved within a single transaction (for example a flash-loan swap that
 *      pushes the price to a position's range edge); splitting the position at that price while valuing the
 *      legs with the oracle would let anyone move the reported market NAV in that transaction. With the
 *      composition and the legs taken from the same oracle, a same-transaction pool swap does not change
 *      the principal.
 *
 *      Fees: pending (uncollected) fees are computed exactly as in `UniswapV4Balance`, from the PoolManager
 *      fee growth inside the range minus the fee growth recorded for the position. Fee growth only increases
 *      by fees actually paid by swappers into the range, so a swap can raise the valuation by at most the
 *      fees it pays to the position; it is not a way to move NAV for free.
 *
 *      Value semantics: when the pool price differs from the oracle price, the result is the value of the
 *      position at the oracle price, not the amount an immediate exit would return. With a delayed feed the
 *      valuation follows the feed, not the pool.
 *
 *      Reverts: there is no fallback to `slot0`. The call reverts when the price oracle middleware is not
 *      set, when the middleware has no price for either currency of a pool with a non-zero liquidity
 *      position (both prices are needed even for a single-sided position), and when the oracle-implied raw
 *      price `token1 / token0` is `>= 2^128` (outside the Q64.96 range). Native-currency pools are not
 *      supported, as in the other V4 fuses (`UniswapV4SubstrateLib`).
 *
 *      At the PoolManager level the position owner is the PositionManager itself and positions are
 *      distinguished by salt = bytes32(tokenId).
 * @author IPOR Labs
 */
contract UniswapV4OracleBalance is IMarketBalanceFuse {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice Thrown when the PositionManager or the PoolManager address is zero
    error UniswapV4OracleBalanceZeroAddress();
    /// @notice Thrown when the vault has no price oracle middleware configured and it tracks at least one position
    error UniswapV4OracleBalancePriceOracleMiddlewareNotSet();

    /// @notice Address of this fuse contract version
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    uint256 public immutable MARKET_ID;

    /// @notice Uniswap V4 PositionManager (periphery) contract address
    address public immutable POSITION_MANAGER;

    /// @notice Uniswap V4 PoolManager (singleton core) contract
    IPoolManager public immutable POOL_MANAGER;

    /**
     * @notice Initializes the UniswapV4OracleBalance fuse with market ID and protocol addresses
     * @param marketId_ The market ID used to identify the market
     * @param positionManager_ The address of the Uniswap V4 PositionManager
     * @param poolManager_ The address of the Uniswap V4 PoolManager
     */
    constructor(uint256 marketId_, address positionManager_, address poolManager_) {
        if (positionManager_ == address(0) || poolManager_ == address(0)) {
            revert UniswapV4OracleBalanceZeroAddress();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        POSITION_MANAGER = positionManager_;
        POOL_MANAGER = IPoolManager(poolManager_);
    }

    /**
     * @notice Calculates the total assets in the market for Uniswap V4 positions
     * @dev For each tracked tokenId: principal (position liquidity split at the oracle-implied sqrt price)
     *      plus pending fees (from fee growth deltas), both converted to USD via the price oracle middleware.
     * @return balance The total balance of assets in the market, normalized to WAD (18 decimals)
     */
    function balanceOf() external view override returns (uint256) {
        uint256[] memory tokenIds = FuseStorageLib.getUniswapV4TokenIds().tokenIds;
        uint256 len = tokenIds.length;

        if (len == 0) {
            return 0;
        }

        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        if (priceOracleMiddleware == address(0)) {
            revert UniswapV4OracleBalancePriceOracleMiddlewareNotSet();
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
            (amount0, amount1) = _principalAmounts(priceOracleMiddleware_, poolKey, info, liquidity);

            (uint256 fees0, uint256 fees1) = _pendingFees(poolKey.toId(), info, tokenId_, liquidity);

            amount0 += fees0;
            amount1 += fees1;
        }

        return
            _amountInUsd(priceOracleMiddleware_, Currency.unwrap(poolKey.currency0), amount0) +
            _amountInUsd(priceOracleMiddleware_, Currency.unwrap(poolKey.currency1), amount1);
    }

    /// @dev Splits the position liquidity into token amounts at the oracle-implied sqrt price of the pool
    /// currencies (never the pool's `slot0`). Reverts when either currency has no price in the middleware
    /// or when the oracle-implied raw price is `>= 2^128` (see `OracleSqrtPriceX96Lib.fromOracle`).
    function _principalAmounts(
        address priceOracleMiddleware_,
        PoolKey memory poolKey_,
        uint256 info_,
        uint128 liquidity_
    ) private view returns (uint256 amount0, uint256 amount1) {
        uint160 sqrtPriceX96 = OracleSqrtPriceX96Lib.fromOracle(
            Currency.unwrap(poolKey_.currency0),
            Currency.unwrap(poolKey_.currency1),
            priceOracleMiddleware_
        );

        (amount0, amount1) = LiquidityAmountsV4.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(PositionInfoLib.tickLower(info_)),
            TickMath.getSqrtPriceAtTick(PositionInfoLib.tickUpper(info_)),
            liquidity_
        );
    }

    /// @dev Same computation as `UniswapV4Balance._pendingFees`: fee growth inside the range (PoolManager
    /// state) minus the fee growth recorded for the position, times the position liquidity.
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

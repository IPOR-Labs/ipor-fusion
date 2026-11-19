// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {OracleSqrtPriceX96Lib} from "../../libraries/math/OracleSqrtPriceX96Lib.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {INonfungiblePositionManagerRamses, IRamsesV2Pool} from "./ext/INonfungiblePositionManagerRamses.sol";
import {LiquidityAmounts} from "./ext/LiquidityAmounts.sol";
import {PoolAddress} from "./ext/PoolAddress.sol";
import {RamsesV2PositionFees} from "./ext/RamsesV2PositionFees.sol";
import {TickMath} from "./ext/TickMath.sol";

/**
 * @title RamsesV2OracleBalance
 * @notice Balance fuse for Ramses V2 positions that derives the token0/token1 composition of every position from
 *         oracle prices instead of the pool's spot price
 * @dev Oracle-priced version of `RamsesV2Balance`. Both versions stay available and the atomist chooses one per
 *      vault. This version reads the same tracked token ID list (`FuseStorageLib.getRamsesV2TokenIds`) and is
 *      deployed with the same `MARKET_ID`, so switching a vault to it is `addBalanceFuse(marketId, fuse)` with no
 *      storage migration.
 *
 *      Composition price: the principal of each position is computed at an oracle-implied `sqrtPriceX96`
 *      (`OracleSqrtPriceX96Lib.fromOracle`, the same derivation as the Slipstream balance fuses after IL-7959),
 *      built from the `PriceOracleMiddleware` prices of the position's token0 and token1. The pool's live
 *      `slot0().sqrtPriceX96` is never read for the principal. The resulting token amounts are valued with the same
 *      middleware, so the composition and the legs come from one source and a swap in the pool within the same
 *      transaction cannot move the principal part of the reported value.
 *
 *      Fees: computed exactly as in `RamsesV2Balance` (`RamsesV2PositionFees.uncollectedFees`): the position
 *      manager's `tokensOwed` plus the fee growth inside the position's range since the position manager's
 *      checkpoint, computed from the pool's current tick, tick fee growth outside values and global fee growth
 *      accumulators (modulo 2^256), times the position's liquidity, i.e. what `collect` would return. The pool's
 *      current tick only selects which fee growth accumulators apply; the accumulators grow only by fees that swaps
 *      actually pay into the pool. A same-transaction swap can therefore raise this part only by the share of its
 *      own swap fee that is credited to the position, which the swapper pays, and it cannot lower it.
 *
 *      Value semantics: when the pool price deviates from the oracle price, the reported value is the value of the
 *      position at the oracle price (the composition it would have if the pool traded at the oracle price, valued
 *      at oracle prices). It is not the amount that an immediate exit at the pool's current price would return.
 *      With a delayed feed the reported value follows the feed with the same delay.
 *
 *      Reverts (no fallback to `slot0`): the vault has no price oracle middleware and it tracks at least one
 *      position; the middleware has no price for token0 or token1 of a tracked position; the oracle-implied raw
 *      price `token1 / token0` is `>= 2^128` (overflow in `OracleSqrtPriceX96Lib.fromOracle`). A revert here blocks
 *      every balance refresh that includes this market, so price feeds for both tokens of every tracked position
 *      must be configured before this fuse is installed.
 * @author IPOR Labs
 */
contract RamsesV2OracleBalance is IMarketBalanceFuse {
    using Address for address;

    /// @notice Thrown when the position manager or the factory address passed to the constructor is zero
    error RamsesV2OracleBalanceZeroAddress();
    /// @notice Thrown when the vault has no price oracle middleware configured and it tracks at least one position
    error RamsesV2OracleBalancePriceOracleMiddlewareNotSet();

    /// @notice Address of this fuse contract version
    /// @dev Immutable value set in constructor, used for tracking and versioning
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    /// @dev Immutable value set in constructor; the same market as `RamsesV2Balance`
    uint256 public immutable MARKET_ID;

    /// @notice Ramses V2 Nonfungible Position Manager contract address
    /// @dev Manages NFTs representing Ramses V2 liquidity positions
    address public immutable NONFUNGIBLE_POSITION_MANAGER;

    /// @notice Ramses V2 factory contract address
    /// @dev Used to compute the pool address of a position for the fee read
    address public immutable RAMSES_FACTORY;

    /**
     * @notice Initializes the fuse with the market ID and the Ramses V2 position manager and factory
     * @param marketId_ The market ID used to identify the market
     * @param nonfungiblePositionManager_ The address of the Ramses V2 Nonfungible Position Manager
     * @param ramsesFactory_ The address of the Ramses V2 factory
     */
    constructor(uint256 marketId_, address nonfungiblePositionManager_, address ramsesFactory_) {
        if (nonfungiblePositionManager_ == address(0) || ramsesFactory_ == address(0)) {
            revert RamsesV2OracleBalanceZeroAddress();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
        RAMSES_FACTORY = ramsesFactory_;
    }

    /**
     * @notice Calculates the total assets in the market for Ramses V2 positions
     * @dev For every tracked position: principal at the oracle-implied `sqrtPriceX96` plus fees (as in
     *      `RamsesV2Balance`), each token amount valued with the price oracle middleware.
     *      Returns 0 without reading the middleware when no position is tracked.
     * @return The total balance of the market in USD, normalized to WAD (18 decimals)
     */
    function balanceOf() external view override returns (uint256) {
        uint256[] memory tokenIds = FuseStorageLib.getRamsesV2TokenIds().tokenIds;
        uint256 len = tokenIds.length;

        if (len == 0) {
            return 0;
        }

        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        if (priceOracleMiddleware == address(0)) {
            revert RamsesV2OracleBalancePriceOracleMiddlewareNotSet();
        }

        uint256 balance;
        address token0;
        address token1;
        uint256 amount0;
        uint256 amount1;

        for (uint256 i; i < len; ++i) {
            (token0, token1, amount0, amount1) = _getAmountsForPosition(tokenIds[i], priceOracleMiddleware);

            balance += _convertToUsd(amount0, token0, priceOracleMiddleware);
            balance += _convertToUsd(amount1, token1, priceOracleMiddleware);
        }

        return balance;
    }

    /// @notice Computes the token amounts of a position: principal at the oracle-implied price plus fees
    /// @param tokenId_ The ID of the position NFT
    /// @param priceOracleMiddleware_ The price oracle middleware of the vault
    /// @return token0 The address of token0
    /// @return token1 The address of token1
    /// @return amount0 The amount of token0 (principal and fees)
    /// @return amount1 The amount of token1 (principal and fees)
    function _getAmountsForPosition(
        uint256 tokenId_,
        address priceOracleMiddleware_
    ) internal view returns (address token0, address token1, uint256 amount0, uint256 amount1) {
        INonfungiblePositionManagerRamses.Position memory position = _getPositionData(tokenId_);

        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(
            OracleSqrtPriceX96Lib.fromOracle(position.token0, position.token1, priceOracleMiddleware_),
            TickMath.getSqrtRatioAtTick(position.tickLower),
            TickMath.getSqrtRatioAtTick(position.tickUpper),
            position.liquidity
        );

        IRamsesV2Pool pool = IRamsesV2Pool(
            PoolAddress.computeAddress(
                RAMSES_FACTORY,
                PoolAddress.getPoolKey(position.token0, position.token1, position.fee)
            )
        );

        (uint256 fee0, uint256 fee1) = RamsesV2PositionFees.uncollectedFees(
            pool,
            position.tickLower,
            position.tickUpper,
            position.liquidity,
            position.feeGrowthInside0Last,
            position.feeGrowthInside1Last
        );

        amount0 += (fee0 + position.tokensOwed0);
        amount1 += (fee1 + position.tokensOwed1);
        token0 = position.token0;
        token1 = position.token1;
    }

    /// @notice Reads the position data of a token ID from the position manager
    /// @param tokenId_ The ID of the position NFT
    /// @return position The position data
    function _getPositionData(
        uint256 tokenId_
    ) internal view returns (INonfungiblePositionManagerRamses.Position memory position) {
        bytes memory returnData = NONFUNGIBLE_POSITION_MANAGER.functionStaticCall(
            abi.encodeWithSelector(INonfungiblePositionManagerRamses.positions.selector, tokenId_)
        );
        position = abi.decode(returnData, (INonfungiblePositionManagerRamses.Position));
    }

    /// @notice Values a token amount in USD with the price oracle middleware
    /// @param amount_ The token amount in the token's own decimals
    /// @param token_ The token address
    /// @param priceOracleMiddleware_ The price oracle middleware of the vault
    /// @return The value in USD, normalized to WAD (18 decimals)
    function _convertToUsd(
        uint256 amount_,
        address token_,
        address priceOracleMiddleware_
    ) internal view returns (uint256) {
        (uint256 priceToken, uint256 priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(
            token_
        );

        return IporMath.convertToWad(amount_ * priceToken, IERC20Metadata(token_).decimals() + priceDecimals);
    }
}

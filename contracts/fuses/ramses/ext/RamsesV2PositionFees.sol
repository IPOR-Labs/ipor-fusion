// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.30;

import {FullMath} from "./FullMath.sol";
import {IRamsesV2Pool} from "./INonfungiblePositionManagerRamses.sol";

/// @title Fees earned by a Ramses V2 position since its last checkpoint, computed from the pool's current fee growth
/// @notice Shared by the Ramses V2 balance fuses (`RamsesV2Balance`, `RamsesV2OracleBalance`)
/// @dev Port of Uniswap v3-periphery `PositionValue._fees` / `_getFeeGrowthInside` (v1.4.4) to Ramses V2 pools, which
/// are a Uniswap V3 fork with the same fee growth accounting (`Tick.getFeeGrowthInside`, `Position.update`). The
/// position manager's `feeGrowthInside{0,1}LastX128` is the checkpoint of the last update of the position (mint,
/// increase, decrease or collect) and equals the checkpoint the pool stores for the position under the position
/// manager's key, so the fees earned since then are `liquidity * (feeGrowthInside - feeGrowthInsideLast) / 2^128`,
/// with `feeGrowthInside` computed here from the pool's current tick, the two ticks' fee growth outside values and the
/// global accumulators. This is the amount the position manager adds to `tokensOwed` when it pokes the position in
/// `collect`. `tokensOwed` itself is not included. Fee growth values are accumulators that only have meaning modulo
/// 2^256 (the pool and the position manager are compiled with solc 0.7.6 and wrap), so every subtraction is
/// `unchecked`; with checked arithmetic a position whose fee growth inside or checkpoint wrapped would revert with an
/// arithmetic panic.
library RamsesV2PositionFees {
    /// @dev 2^128, the fixed-point scale of fee growth values (`FixedPoint128.Q128`)
    uint256 internal constant Q128 = 0x100000000000000000000000000000000;

    /// @notice Fees earned by a position since its last checkpoint, not yet added to its `tokensOwed`
    /// @dev Returns zero without reading the pool when the position has no liquidity (no fees can accrue to it)
    /// @param pool_ The Ramses V2 pool of the position
    /// @param tickLower_ The lower tick of the position
    /// @param tickUpper_ The upper tick of the position
    /// @param liquidity_ The liquidity of the position
    /// @param feeGrowthInside0LastX128_ The position manager's fee growth checkpoint for token0
    /// @param feeGrowthInside1LastX128_ The position manager's fee growth checkpoint for token1
    /// @return fee0 The fees earned in token0 since the checkpoint
    /// @return fee1 The fees earned in token1 since the checkpoint
    function uncollectedFees(
        IRamsesV2Pool pool_,
        int24 tickLower_,
        int24 tickUpper_,
        uint128 liquidity_,
        uint256 feeGrowthInside0LastX128_,
        uint256 feeGrowthInside1LastX128_
    ) internal view returns (uint256 fee0, uint256 fee1) {
        if (liquidity_ == 0) {
            return (0, 0);
        }

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = getFeeGrowthInside(
            pool_,
            tickLower_,
            tickUpper_
        );

        uint256 feeGrowthDelta0X128;
        uint256 feeGrowthDelta1X128;
        unchecked {
            feeGrowthDelta0X128 = feeGrowthInside0X128 - feeGrowthInside0LastX128_;
            feeGrowthDelta1X128 = feeGrowthInside1X128 - feeGrowthInside1LastX128_;
        }

        fee0 = FullMath.mulDiv(feeGrowthDelta0X128, liquidity_, Q128);
        fee1 = FullMath.mulDiv(feeGrowthDelta1X128, liquidity_, Q128);
    }

    /// @notice All-time fee growth per unit of liquidity inside the tick range, as the pool computes it
    /// @dev Equals Ramses V2 `Tick.getFeeGrowthInside` modulo 2^256: below the range the inside growth is
    /// `lowerOutside - upperOutside`, inside the range `global - lowerOutside - upperOutside`, above the range
    /// `upperOutside - lowerOutside`. Tick fee growth outside values are relative to when each tick was initialized,
    /// so these differences legitimately wrap below zero; the pool relies on solc 0.7.6 wrapping arithmetic,
    /// reproduced here with `unchecked`.
    /// @param pool_ The Ramses V2 pool of the position
    /// @param tickLower_ The lower tick of the position
    /// @param tickUpper_ The upper tick of the position
    /// @return feeGrowthInside0X128 The all-time fee growth in token0 inside the range, modulo 2^256
    /// @return feeGrowthInside1X128 The all-time fee growth in token1 inside the range, modulo 2^256
    function getFeeGrowthInside(
        IRamsesV2Pool pool_,
        int24 tickLower_,
        int24 tickUpper_
    ) internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        (, int24 tickCurrent, , , , , ) = pool_.slot0();
        (, , , , uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128, , , , ) = pool_.ticks(
            tickLower_
        );
        (, , , , uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128, , , , ) = pool_.ticks(
            tickUpper_
        );

        if (tickCurrent < tickLower_) {
            unchecked {
                feeGrowthInside0X128 = lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            }
        } else if (tickCurrent < tickUpper_) {
            uint256 feeGrowthGlobal0X128 = pool_.feeGrowthGlobal0X128();
            uint256 feeGrowthGlobal1X128 = pool_.feeGrowthGlobal1X128();
            unchecked {
                feeGrowthInside0X128 = feeGrowthGlobal0X128 - lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = feeGrowthGlobal1X128 - lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            }
        } else {
            unchecked {
                feeGrowthInside0X128 = upperFeeGrowthOutside0X128 - lowerFeeGrowthOutside0X128;
                feeGrowthInside1X128 = upperFeeGrowthOutside1X128 - lowerFeeGrowthOutside1X128;
            }
        }
    }
}

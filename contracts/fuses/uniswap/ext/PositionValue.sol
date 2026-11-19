// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.30;

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/libraries/FixedPoint128.sol";

import {FullMath} from "./FullMath.sol";
import {INonfungiblePositionManager} from "./INonfungiblePositionManager.sol";
import {LiquidityAmounts} from "./LiquidityAmounts.sol";
import {PoolAddress} from "./PoolAddress.sol";
import {TickMath} from "./TickMath.sol";

/// @title Returns information about the token value held in a Uniswap V3 NFT
library PositionValue {
    error InvalidReturnData();

    /// @notice Extracts tickLower, tickUpper, and liquidity from a position using assembly for gas optimization.
    /// @param positionManager_ The Uniswap V3 NonfungiblePositionManager
    /// @param tokenId_ The tokenId of the token for which to get the position info
    /// @return tickLower The lower end of the tick range for the position
    /// @return tickUpper The higher end of the tick range for the position
    /// @return liquidity The liquidity of the position
    function getPositionTicksAndLiquidity(
        INonfungiblePositionManager positionManager_,
        uint256 tokenId_
    ) internal view returns (int24 tickLower, int24 tickUpper, uint128 liquidity) {
        address positionManagerAddress = address(positionManager_);
        bytes memory callData = abi.encodeWithSelector(INonfungiblePositionManager.positions.selector, tokenId_);

        bool success;
        bytes memory returnData;
        assembly {
            let callDataLength := mload(callData)
            let callDataPointer := add(callData, 0x20)
            success := staticcall(gas(), positionManagerAddress, callDataPointer, callDataLength, 0, 0)
            let returnDataSize := returndatasize()
            returnData := mload(0x40)
            mstore(returnData, returnDataSize)
            mstore(0x40, add(returnData, add(returnDataSize, 0x20)))
            returndatacopy(add(returnData, 0x20), 0, returnDataSize)
        }

        if (!success || returnData.length < 256) revert InvalidReturnData();

        assembly {
            // tickLower at offset 5: 32 (length) + 32 * 5 = 192
            // tickUpper at offset 6: 32 (length) + 32 * 6 = 224
            // liquidity at offset 7: 32 (length) + 32 * 7 = 256
            // In ABI encoding, signed integers are sign-extended to 32 bytes, so Solidity will handle conversion
            tickLower := mload(add(returnData, 192))
            tickUpper := mload(add(returnData, 224))
            liquidity := and(mload(add(returnData, 256)), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        }
    }

    /// @notice Extracts all position data needed for fee calculation using assembly for gas optimization.
    /// @param positionManager_ The Uniswap V3 NonfungiblePositionManager
    /// @param tokenId_ The tokenId of the token for which to get the position info
    /// @return feeParams The FeeParams struct containing all position data
    function getPositionFeeParams(
        INonfungiblePositionManager positionManager_,
        uint256 tokenId_
    ) internal view returns (FeeParams memory feeParams) {
        address positionManagerAddress = address(positionManager_);
        bytes memory callData = abi.encodeWithSelector(INonfungiblePositionManager.positions.selector, tokenId_);

        bool success;
        bytes memory returnData;
        assembly {
            let callDataLength := mload(callData)
            let callDataPointer := add(callData, 0x20)
            success := staticcall(gas(), positionManagerAddress, callDataPointer, callDataLength, 0, 0)
            let returnDataSize := returndatasize()
            returnData := mload(0x40)
            mstore(returnData, returnDataSize)
            mstore(0x40, add(returnData, add(returnDataSize, 0x20)))
            returndatacopy(add(returnData, 0x20), 0, returnDataSize)
        }

        if (!success || returnData.length < 384) revert InvalidReturnData();

        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 positionFeeGrowthInside0LastX128;
        uint256 positionFeeGrowthInside1LastX128;
        uint256 tokensOwed0;
        uint256 tokensOwed1;
        assembly {
            token0 := mload(add(returnData, 96))
            token1 := mload(add(returnData, 128))
            fee := and(mload(add(returnData, 160)), 0xFFFFFF)
            tickLower := mload(add(returnData, 192))
            tickUpper := mload(add(returnData, 224))
            liquidity := and(mload(add(returnData, 256)), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            positionFeeGrowthInside0LastX128 := mload(add(returnData, 288))
            positionFeeGrowthInside1LastX128 := mload(add(returnData, 320))
            tokensOwed0 := and(mload(add(returnData, 352)), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            tokensOwed1 := and(mload(add(returnData, 384)), 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        }

        feeParams = FeeParams(
            token0,
            token1,
            fee,
            tickLower,
            tickUpper,
            liquidity,
            positionFeeGrowthInside0LastX128,
            positionFeeGrowthInside1LastX128,
            tokensOwed0,
            tokensOwed1
        );
    }

    /// @notice Returns the total amounts of token0 and token1, i.e. the sum of fees and principal
    /// that a given nonfungible position manager token is worth
    /// @param positionManager The Uniswap V3 NonfungiblePositionManager
    /// @param tokenId The tokenId of the token for which to get the total value
    /// @param sqrtRatioX96 The square root price X96 for which to calculate the principal amounts
    /// @return amount0 The total amount of token0 including principal and fees
    /// @return amount1 The total amount of token1 including principal and fees
    function total(
        INonfungiblePositionManager positionManager,
        uint256 tokenId,
        uint160 sqrtRatioX96
    ) internal view returns (uint256 amount0, uint256 amount1) {
        (uint256 amount0Principal, uint256 amount1Principal) = principal(positionManager, tokenId, sqrtRatioX96);
        (uint256 amount0Fee, uint256 amount1Fee) = fees(positionManager, tokenId);
        return (amount0Principal + amount0Fee, amount1Principal + amount1Fee);
    }

    /// @notice Calculates the principal (currently acting as liquidity) owed to the token owner in the event
    /// that the position is burned
    /// @param positionManager The Uniswap V3 NonfungiblePositionManager
    /// @param tokenId The tokenId of the token for which to get the total principal owed
    /// @param sqrtRatioX96 The square root price X96 for which to calculate the principal amounts
    /// @return amount0 The principal amount of token0
    /// @return amount1 The principal amount of token1
    function principal(
        INonfungiblePositionManager positionManager,
        uint256 tokenId,
        uint160 sqrtRatioX96
    ) internal view returns (uint256 amount0, uint256 amount1) {
        (int24 tickLower, int24 tickUpper, uint128 liquidity) = getPositionTicksAndLiquidity(positionManager, tokenId);

        return
            LiquidityAmounts.getAmountsForLiquidity(
                sqrtRatioX96,
                TickMath.getSqrtRatioAtTick(tickLower),
                TickMath.getSqrtRatioAtTick(tickUpper),
                liquidity
            );
    }

    struct FeeParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 positionFeeGrowthInside0LastX128;
        uint256 positionFeeGrowthInside1LastX128;
        uint256 tokensOwed0;
        uint256 tokensOwed1;
    }

    /// @notice Calculates the total fees owed to the token owner
    /// @param positionManager The Uniswap V3 NonfungiblePositionManager
    /// @param tokenId The tokenId of the token for which to get the total fees owed
    /// @return amount0 The amount of fees owed in token0
    /// @return amount1 The amount of fees owed in token1
    function fees(
        INonfungiblePositionManager positionManager,
        uint256 tokenId
    ) internal view returns (uint256 amount0, uint256 amount1) {
        FeeParams memory feeParams = getPositionFeeParams(positionManager, tokenId);

        return _fees(positionManager, feeParams);
    }

    /// @notice Fees owed to a position: `tokensOwed` plus the fee growth inside the range since the position's last
    /// snapshot, times its liquidity
    /// @dev Port of Uniswap v3-periphery `PositionValue._fees` (v1.4.4), compiled there with solc < 0.8.0. Uniswap V3
    /// fee growth values are accumulators that only have meaning modulo 2^256 (v3-core `Position.update` and the
    /// `NonfungiblePositionManager` take the same difference with wrapping arithmetic), so
    /// `feeGrowthInside - feeGrowthInsideLast` is computed in an `unchecked` block. With checked arithmetic a position
    /// whose fee growth inside wrapped would revert with an arithmetic panic. The `tokensOwed` addition stays checked.
    /// @param positionManager The Uniswap V3 NonfungiblePositionManager
    /// @param feeParams The position data read from the NonfungiblePositionManager
    /// @return amount0 The amount of fees owed in token0
    /// @return amount1 The amount of fees owed in token1
    function _fees(
        INonfungiblePositionManager positionManager,
        FeeParams memory feeParams
    ) internal view returns (uint256 amount0, uint256 amount1) {
        (uint256 poolFeeGrowthInside0LastX128, uint256 poolFeeGrowthInside1LastX128) = _getFeeGrowthInside(
            IUniswapV3Pool(
                PoolAddress.computeAddress(
                    positionManager.factory(),
                    PoolAddress.PoolKey({token0: feeParams.token0, token1: feeParams.token1, fee: feeParams.fee})
                )
            ),
            feeParams.tickLower,
            feeParams.tickUpper
        );

        uint256 feeGrowthDelta0X128;
        uint256 feeGrowthDelta1X128;
        unchecked {
            feeGrowthDelta0X128 = poolFeeGrowthInside0LastX128 - feeParams.positionFeeGrowthInside0LastX128;
            feeGrowthDelta1X128 = poolFeeGrowthInside1LastX128 - feeParams.positionFeeGrowthInside1LastX128;
        }

        amount0 = FullMath.mulDiv(feeGrowthDelta0X128, feeParams.liquidity, FixedPoint128.Q128) + feeParams.tokensOwed0;

        amount1 = FullMath.mulDiv(feeGrowthDelta1X128, feeParams.liquidity, FixedPoint128.Q128) + feeParams.tokensOwed1;
    }

    /// @notice All-time fee growth per unit of liquidity inside the tick range, as the pool computes it
    /// @dev Port of Uniswap v3-periphery `PositionValue._getFeeGrowthInside` (v1.4.4), which equals v3-core
    /// `Tick.getFeeGrowthInside` (v1.0.1) modulo 2^256: below the range the inside growth is
    /// `lowerOutside - upperOutside`, inside the range `global - lowerOutside - upperOutside`, above the range
    /// `upperOutside - lowerOutside`. Tick fee growth outside values are relative to when each tick was initialized,
    /// so these differences legitimately wrap below zero (for example when the two ticks' outside values sum above
    /// the global value); Uniswap relies on solc < 0.8.0 wrapping arithmetic, reproduced here with `unchecked`.
    /// @param pool The Uniswap V3 pool of the position
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @return feeGrowthInside0X128 The all-time fee growth in token0 inside the range, modulo 2^256
    /// @return feeGrowthInside1X128 The all-time fee growth in token1 inside the range, modulo 2^256
    function _getFeeGrowthInside(
        IUniswapV3Pool pool,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        (, int24 tickCurrent, , , , , ) = pool.slot0();
        (, , uint256 lowerFeeGrowthOutside0X128, uint256 lowerFeeGrowthOutside1X128, , , , ) = pool.ticks(tickLower);
        (, , uint256 upperFeeGrowthOutside0X128, uint256 upperFeeGrowthOutside1X128, , , , ) = pool.ticks(tickUpper);

        if (tickCurrent < tickLower) {
            unchecked {
                feeGrowthInside0X128 = lowerFeeGrowthOutside0X128 - upperFeeGrowthOutside0X128;
                feeGrowthInside1X128 = lowerFeeGrowthOutside1X128 - upperFeeGrowthOutside1X128;
            }
        } else if (tickCurrent < tickUpper) {
            uint256 feeGrowthGlobal0X128 = pool.feeGrowthGlobal0X128();
            uint256 feeGrowthGlobal1X128 = pool.feeGrowthGlobal1X128();
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

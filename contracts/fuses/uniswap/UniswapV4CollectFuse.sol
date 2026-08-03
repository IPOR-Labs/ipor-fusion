// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IPositionManagerV4} from "./ext/v4/IPositionManagerV4.sol";
import {ActionsV4} from "./ext/v4/ActionsV4.sol";

/// @notice Data for collecting fees from Uniswap V4 positions
struct UniswapV4CollectFuseEnterData {
    /// @notice Array of NFT token IDs representing Uniswap V4 liquidity positions to collect fees from
    uint256[] tokenIds;
}

/// @title UniswapV4CollectFuse
/// @notice Fuse for collecting accrued fees from Uniswap V4 liquidity positions
/// @dev In V4 there is no dedicated collect call; fees are realized by DECREASE_LIQUIDITY with
///      liquidity = 0 followed by TAKE_PAIR to the vault. Position liquidity is unchanged.
///      Associated with fuse balance UniswapV4Balance.
contract UniswapV4CollectFuse is IFuseCommon {
    event UniswapV4CollectFuseEnter(address version, uint256 tokenId, uint256 amount0, uint256 amount1);

    error UniswapV4CollectFuseInvalidAddress();
    error UniswapV4CollectFuseTokenIdNotTracked(uint256 tokenId);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    /// @dev Uniswap V4 PositionManager (periphery), manages NFTs representing liquidity positions
    address public immutable POSITION_MANAGER;

    constructor(uint256 marketId_, address positionManager_) {
        if (positionManager_ == address(0)) {
            revert UniswapV4CollectFuseInvalidAddress();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        POSITION_MANAGER = positionManager_;
    }

    /// @notice Collects accrued fees from Uniswap V4 positions into the vault
    /// @param data_ The data containing array of token IDs to collect from
    /// @return totalAmount0 Total amount of token0 collected across all positions
    /// @return totalAmount1 Total amount of token1 collected across all positions
    function enter(
        UniswapV4CollectFuseEnterData memory data_
    ) public returns (uint256 totalAmount0, uint256 totalAmount1) {
        uint256 len = data_.tokenIds.length;

        if (len == 0) {
            return (0, 0);
        }

        uint256 amount0;
        uint256 amount1;

        for (uint256 i; i < len; ++i) {
            (amount0, amount1) = _collectSingle(data_.tokenIds[i]);

            totalAmount0 += amount0;
            totalAmount1 += amount1;

            emit UniswapV4CollectFuseEnter(VERSION, data_.tokenIds[i], amount0, amount1);
        }
    }

    /// @notice Enters the Fuse using transient storage for parameters
    /// @dev Inputs: [0] length n, [1..n] tokenIds
    function enterTransient() external {
        uint256 len = TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, 0));

        uint256[] memory tokenIds = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            tokenIds[i] = TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, i + 1));
        }

        (uint256 totalAmount0, uint256 totalAmount1) = enter(UniswapV4CollectFuseEnterData(tokenIds));

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(totalAmount0);
        outputs[1] = TypeConversionLib.toBytes32(totalAmount1);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    function _collectSingle(uint256 tokenId_) private returns (uint256 amount0, uint256 amount1) {
        _requireTracked(tokenId_);

        /// @dev Poking a zero-liquidity position reverts in v4-core (CannotUpdateEmptyPosition); such
        /// positions have no pending fees (they were realized by the decrease that emptied them), so
        /// they are skipped instead of failing the whole batch.
        if (IPositionManagerV4(POSITION_MANAGER).getPositionLiquidity(tokenId_) == 0) {
            return (0, 0);
        }

        (PoolKey memory poolKey, ) = IPositionManagerV4(POSITION_MANAGER).getPoolAndPositionInfo(tokenId_);

        address token0 = Currency.unwrap(poolKey.currency0);
        address token1 = Currency.unwrap(poolKey.currency1);

        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));

        bytes[] memory params = new bytes[](2);
        /// @dev DECREASE_LIQUIDITY with liquidity = 0 realizes all accrued fees; amount*Min = 0 is
        /// acceptable because fees are not subject to principal-style sandwiching.
        params[0] = abi.encode(tokenId_, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));

        IPositionManagerV4(POSITION_MANAGER).modifyLiquidities(
            abi.encode(abi.encodePacked(ActionsV4.DECREASE_LIQUIDITY, ActionsV4.TAKE_PAIR), params),
            block.timestamp
        );

        amount0 = IERC20(token0).balanceOf(address(this)) - balance0Before;
        amount1 = IERC20(token1).balanceOf(address(this)) - balance1Before;
    }

    /// @dev Only tokenIds registered by UniswapV4NewPositionFuse.enter (owned by the vault and counted
    /// by UniswapV4Balance) can be collected from.
    function _requireTracked(uint256 tokenId_) private view {
        FuseStorageLib.UniswapV4TokenIds storage tokensIds = FuseStorageLib.getUniswapV4TokenIds();

        uint256 index = tokensIds.indexes[tokenId_];

        if (index >= tokensIds.tokenIds.length || tokensIds.tokenIds[index] != tokenId_) {
            revert UniswapV4CollectFuseTokenIdNotTracked(tokenId_);
        }
    }
}

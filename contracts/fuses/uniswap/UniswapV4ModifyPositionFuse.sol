// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IPermit2} from "../balancer/ext/IPermit2.sol";
import {IPositionManagerV4} from "./ext/v4/IPositionManagerV4.sol";
import {ActionsV4} from "./ext/v4/ActionsV4.sol";
import {LiquidityAmountsV4} from "./ext/v4/LiquidityAmountsV4.sol";
import {PositionInfoLib} from "./ext/v4/PositionInfoLib.sol";
import {UniswapV4SubstrateLib} from "./UniswapV4SubstrateLib.sol";

/// @notice Data for entering UniswapV4ModifyPositionFuse - increase liquidity
struct UniswapV4ModifyPositionFuseEnterData {
    /// @notice tokenId The ID of the NFT that represents the minted position
    uint256 tokenId;
    /// @notice The desired amount of token0 to be spent (used to compute the liquidity delta)
    uint256 amount0Desired;
    /// @notice The desired amount of token1 to be spent (used to compute the liquidity delta)
    uint256 amount1Desired;
    /// @notice The maximum amount of token0 to spend, which serves as a slippage check
    uint256 amount0Max;
    /// @notice The maximum amount of token1 to spend, which serves as a slippage check
    uint256 amount1Max;
    /// @notice Arbitrary data passed to the pool's hook (empty for hookless pools)
    bytes hookData;
    /// @notice Deadline for the transaction
    uint256 deadline;
}

/// @notice Data for exiting UniswapV4ModifyPositionFuse - decrease liquidity
struct UniswapV4ModifyPositionFuseExitData {
    /// @notice tokenId The ID of the NFT for which liquidity is being decreased
    uint256 tokenId;
    /// @notice The amount by which liquidity will be decreased (capped at the position's liquidity)
    uint128 liquidity;
    /// @notice The minimum amount of token0 to receive, which serves as a slippage check
    uint256 amount0Min;
    /// @notice The minimum amount of token1 to receive, which serves as a slippage check
    uint256 amount1Min;
    /// @notice Arbitrary data passed to the pool's hook (empty for hookless pools)
    bytes hookData;
    /// @notice Deadline for the transaction
    uint256 deadline;
}

/// @title UniswapV4ModifyPositionFuse
/// @notice Fuse for modifying existing Uniswap V4 liquidity positions
/// @dev enter increases liquidity (INCREASE_LIQUIDITY + SETTLE_PAIR, tokens paid via Permit2),
///      exit decreases liquidity (DECREASE_LIQUIDITY + TAKE_PAIR); unlike V3, the decreased amounts
///      (plus all accrued fees) are transferred to the vault within the same call.
///      The position NFT is not burned. Associated with fuse balance UniswapV4Balance.
contract UniswapV4ModifyPositionFuse is IFuseCommon {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    event UniswapV4ModifyPositionFuseEnter(
        address version,
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    event UniswapV4ModifyPositionFuseExit(address version, uint256 tokenId, uint256 amount0, uint256 amount1);

    error UniswapV4ModifyPositionFuseZeroLiquidity();
    error UniswapV4ModifyPositionFuseInvalidAddress();
    error UniswapV4ModifyPositionFuseTokenIdNotTracked(uint256 tokenId);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    /// @dev Uniswap V4 PositionManager (periphery), manages NFTs representing liquidity positions
    address public immutable POSITION_MANAGER;
    /// @dev Uniswap V4 PoolManager (singleton core), read for the current pool price
    IPoolManager public immutable POOL_MANAGER;
    /// @dev Canonical Permit2; the V4 PositionManager pulls ERC-20 tokens through it
    address public immutable PERMIT2;

    constructor(uint256 marketId_, address positionManager_, address poolManager_, address permit2_) {
        if (positionManager_ == address(0) || poolManager_ == address(0) || permit2_ == address(0)) {
            revert UniswapV4ModifyPositionFuseInvalidAddress();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        POSITION_MANAGER = positionManager_;
        POOL_MANAGER = IPoolManager(poolManager_);
        PERMIT2 = permit2_;
    }

    /// @notice Increases liquidity for an existing Uniswap V4 position
    /// @param data_ The data structure containing the parameters for increasing liquidity
    /// @return tokenId The ID of the NFT that represents the position
    /// @return liquidity The amount of liquidity added
    /// @return amount0 The amount of token0 spent
    /// @return amount1 The amount of token1 spent
    function enter(
        UniswapV4ModifyPositionFuseEnterData memory data_
    ) public returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        _requireTracked(data_.tokenId);

        (PoolKey memory poolKey, uint256 info) = IPositionManagerV4(POSITION_MANAGER).getPoolAndPositionInfo(
            data_.tokenId
        );

        UniswapV4SubstrateLib.checkPoolKeyGranted(MARKET_ID, poolKey);

        liquidity = _calculateLiquidity(poolKey, info, data_.amount0Desired, data_.amount1Desired);

        if (liquidity == 0) {
            revert UniswapV4ModifyPositionFuseZeroLiquidity();
        }

        address token0 = Currency.unwrap(poolKey.currency0);
        address token1 = Currency.unwrap(poolKey.currency1);

        _approvePermit2(token0, data_.amount0Max);
        _approvePermit2(token1, data_.amount1Max);

        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            data_.tokenId,
            uint256(liquidity),
            data_.amount0Max.toUint128(),
            data_.amount1Max.toUint128(),
            data_.hookData
        );
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

        IPositionManagerV4(POSITION_MANAGER).modifyLiquidities(
            abi.encode(abi.encodePacked(ActionsV4.INCREASE_LIQUIDITY, ActionsV4.SETTLE_PAIR), params),
            data_.deadline
        );

        _resetPermit2(token0);
        _resetPermit2(token1);

        tokenId = data_.tokenId;
        amount0 = balance0Before - IERC20(token0).balanceOf(address(this));
        amount1 = balance1Before - IERC20(token1).balanceOf(address(this));

        emit UniswapV4ModifyPositionFuseEnter(VERSION, tokenId, liquidity, amount0, amount1);
    }

    /// @notice Decreases liquidity for an existing Uniswap V4 position; received amounts (including
    ///         all accrued fees) are transferred to the vault
    /// @param data_ The data structure containing the parameters for decreasing liquidity
    /// @return tokenId The ID of the NFT for which liquidity was decreased
    /// @return amount0 The amount of token0 received
    /// @return amount1 The amount of token1 received
    function exit(
        UniswapV4ModifyPositionFuseExitData memory data_
    ) public returns (uint256 tokenId, uint256 amount0, uint256 amount1) {
        _requireTracked(data_.tokenId);

        (PoolKey memory poolKey, ) = IPositionManagerV4(POSITION_MANAGER).getPoolAndPositionInfo(data_.tokenId);

        uint128 positionLiquidity = IPositionManagerV4(POSITION_MANAGER).getPositionLiquidity(data_.tokenId);
        uint128 liquidity = data_.liquidity > positionLiquidity ? positionLiquidity : data_.liquidity;

        if (liquidity == 0) {
            revert UniswapV4ModifyPositionFuseZeroLiquidity();
        }

        address token0 = Currency.unwrap(poolKey.currency0);
        address token1 = Currency.unwrap(poolKey.currency1);

        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            data_.tokenId,
            uint256(liquidity),
            data_.amount0Min.toUint128(),
            data_.amount1Min.toUint128(),
            data_.hookData
        );
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1, address(this));

        IPositionManagerV4(POSITION_MANAGER).modifyLiquidities(
            abi.encode(abi.encodePacked(ActionsV4.DECREASE_LIQUIDITY, ActionsV4.TAKE_PAIR), params),
            data_.deadline
        );

        tokenId = data_.tokenId;
        amount0 = IERC20(token0).balanceOf(address(this)) - balance0Before;
        amount1 = IERC20(token1).balanceOf(address(this)) - balance1Before;

        emit UniswapV4ModifyPositionFuseExit(VERSION, tokenId, amount0, amount1);
    }

    /// @notice Enters the Fuse using transient storage for parameters
    /// @dev Inputs: [0] tokenId, [1] amount0Desired, [2] amount1Desired, [3] amount0Max, [4] amount1Max,
    ///      [5] deadline. hookData is always empty in the transient variant.
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = enter(
            UniswapV4ModifyPositionFuseEnterData({
                tokenId: TypeConversionLib.toUint256(inputs[0]),
                amount0Desired: TypeConversionLib.toUint256(inputs[1]),
                amount1Desired: TypeConversionLib.toUint256(inputs[2]),
                amount0Max: TypeConversionLib.toUint256(inputs[3]),
                amount1Max: TypeConversionLib.toUint256(inputs[4]),
                hookData: bytes(""),
                deadline: TypeConversionLib.toUint256(inputs[5])
            })
        );

        bytes32[] memory outputs = new bytes32[](4);
        outputs[0] = TypeConversionLib.toBytes32(tokenId);
        outputs[1] = TypeConversionLib.toBytes32(uint256(liquidity));
        outputs[2] = TypeConversionLib.toBytes32(amount0);
        outputs[3] = TypeConversionLib.toBytes32(amount1);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits the Fuse using transient storage for parameters
    /// @dev Inputs: [0] tokenId, [1] liquidity, [2] amount0Min, [3] amount1Min, [4] deadline.
    ///      hookData is always empty in the transient variant.
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        (uint256 tokenId, uint256 amount0, uint256 amount1) = exit(
            UniswapV4ModifyPositionFuseExitData({
                tokenId: TypeConversionLib.toUint256(inputs[0]),
                liquidity: SafeCast.toUint128(TypeConversionLib.toUint256(inputs[1])),
                amount0Min: TypeConversionLib.toUint256(inputs[2]),
                amount1Min: TypeConversionLib.toUint256(inputs[3]),
                hookData: bytes(""),
                deadline: TypeConversionLib.toUint256(inputs[4])
            })
        );

        bytes32[] memory outputs = new bytes32[](3);
        outputs[0] = TypeConversionLib.toBytes32(tokenId);
        outputs[1] = TypeConversionLib.toBytes32(amount0);
        outputs[2] = TypeConversionLib.toBytes32(amount1);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @dev The V4 PositionManager does not permission INCREASE_LIQUIDITY (unlike DECREASE/BURN), so
    /// vault funds could otherwise be added to a position the vault neither owns nor tracks. Only
    /// tokenIds registered by UniswapV4NewPositionFuse.enter (and therefore owned by the vault and
    /// counted by UniswapV4Balance) can be modified.
    function _requireTracked(uint256 tokenId_) private view {
        FuseStorageLib.UniswapV4TokenIds storage tokensIds = FuseStorageLib.getUniswapV4TokenIds();

        uint256 index = tokensIds.indexes[tokenId_];

        if (index >= tokensIds.tokenIds.length || tokensIds.tokenIds[index] != tokenId_) {
            revert UniswapV4ModifyPositionFuseTokenIdNotTracked(tokenId_);
        }
    }

    function _calculateLiquidity(
        PoolKey memory poolKey_,
        uint256 info_,
        uint256 amount0Desired_,
        uint256 amount1Desired_
    ) private view returns (uint128) {
        (uint160 sqrtPriceX96, , , ) = POOL_MANAGER.getSlot0(poolKey_.toId());

        return
            LiquidityAmountsV4.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(PositionInfoLib.tickLower(info_)),
                TickMath.getSqrtPriceAtTick(PositionInfoLib.tickUpper(info_)),
                amount0Desired_,
                amount1Desired_
            );
    }

    function _approvePermit2(address token_, uint256 amount_) private {
        IERC20(token_).forceApprove(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(token_, POSITION_MANAGER, amount_.toUint160(), uint48(block.timestamp + 1));
    }

    function _resetPermit2(address token_) private {
        IPermit2(PERMIT2).approve(token_, POSITION_MANAGER, 0, 0);
        IERC20(token_).forceApprove(PERMIT2, 0);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
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
import {UniswapV4SubstrateLib} from "./UniswapV4SubstrateLib.sol";

/// @notice Data for entering a new position in Uniswap V4
struct UniswapV4NewPositionFuseEnterData {
    /// @notice The pool key (currency0, currency1, fee, tickSpacing, hooks) identifying the Uniswap V4 pool
    PoolKey poolKey;
    /// @notice The lower end of the tick range for the position
    int24 tickLower;
    /// @notice The higher end of the tick range for the position
    int24 tickUpper;
    /// @notice The amount of token0 desired to be spent (used to compute the liquidity to mint)
    uint256 amount0Desired;
    /// @notice The amount of token1 desired to be spent (used to compute the liquidity to mint)
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

/// @notice Data for closing positions on Uniswap V4
struct UniswapV4NewPositionFuseExitData {
    /// @notice Token IDs to close, NFTs minted by the Uniswap V4 PositionManager
    uint256[] tokenIds;
    /// @notice The minimum amount of token0 to receive per position, which serves as a slippage check
    uint256[] amount0Min;
    /// @notice The minimum amount of token1 to receive per position, which serves as a slippage check
    uint256[] amount1Min;
    /// @notice Arbitrary data passed to the pool's hook (empty for hookless pools)
    bytes hookData;
    /// @notice Deadline for the transaction
    uint256 deadline;
}

/// @title UniswapV4NewPositionFuse
/// @notice Fuse for creating and closing Uniswap V4 concentrated liquidity positions
/// @dev enter mints a new position (MINT_POSITION + SETTLE_PAIR, tokens paid via Permit2),
///      exit burns positions (BURN_POSITION + TAKE_PAIR, principal + accrued fees returned to the vault).
///      Associated with fuse balance UniswapV4Balance.
contract UniswapV4NewPositionFuse is IFuseCommon {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    event UniswapV4NewPositionFuseEnter(
        address version,
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1,
        bytes32 poolId,
        int24 tickLower,
        int24 tickUpper
    );

    event UniswapV4NewPositionFuseExit(address version, uint256 tokenId, uint256 amount0, uint256 amount1);

    error UniswapV4NewPositionFuseZeroLiquidity();
    error UniswapV4NewPositionFuseInvalidTokenId(uint256 tokenId);
    error UniswapV4NewPositionFuseTokenIdNotTracked(uint256 tokenId);
    error UniswapV4NewPositionFuseInvalidArrayLength();
    error UniswapV4NewPositionFuseInvalidAddress();

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
            revert UniswapV4NewPositionFuseInvalidAddress();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        POSITION_MANAGER = positionManager_;
        POOL_MANAGER = IPoolManager(poolManager_);
        PERMIT2 = permit2_;
    }

    /// @notice Opens a new Uniswap V4 position, minting the position NFT to the vault.
    /// @param data_ The data required to enter the new position.
    /// @return tokenId The ID of the NFT token representing the position
    /// @return liquidity The amount of liquidity minted
    /// @return amount0 The amount of token0 spent
    /// @return amount1 The amount of token1 spent
    function enter(
        UniswapV4NewPositionFuseEnterData memory data_
    ) public returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        UniswapV4SubstrateLib.checkPoolKeyGranted(MARKET_ID, data_.poolKey);

        liquidity = _calculateLiquidity(data_);

        if (liquidity == 0) {
            revert UniswapV4NewPositionFuseZeroLiquidity();
        }

        /// @dev The PositionManager assigns nextTokenId to the minted position and increments it; the whole
        /// FuseAction is atomic, so this read is a deterministic preview of the minted tokenId.
        tokenId = IPositionManagerV4(POSITION_MANAGER).nextTokenId();

        (amount0, amount1) = _mintPosition(data_, liquidity);

        if (IPositionManagerV4(POSITION_MANAGER).ownerOf(tokenId) != address(this)) {
            revert UniswapV4NewPositionFuseInvalidTokenId(tokenId);
        }

        FuseStorageLib.UniswapV4TokenIds storage tokensIds = FuseStorageLib.getUniswapV4TokenIds();
        tokensIds.indexes[tokenId] = tokensIds.tokenIds.length;
        tokensIds.tokenIds.push(tokenId);

        _emitEnter(data_, tokenId, liquidity, amount0, amount1);
    }

    /// @notice Closes one or more Uniswap V4 positions: burns the NFTs and returns principal + accrued
    ///         fees to the vault.
    /// @param data_ The data required to exit the positions.
    /// @return tokenIds The array of token IDs that were closed
    function exit(UniswapV4NewPositionFuseExitData memory data_) public returns (uint256[] memory tokenIds) {
        uint256 len = data_.tokenIds.length;

        if (len != data_.amount0Min.length || len != data_.amount1Min.length) {
            revert UniswapV4NewPositionFuseInvalidArrayLength();
        }

        FuseStorageLib.UniswapV4TokenIds storage tokensIds = FuseStorageLib.getUniswapV4TokenIds();

        tokenIds = new uint256[](len);

        for (uint256 i; i < len; ++i) {
            tokenIds[i] = data_.tokenIds[i];
            _exitSingle(
                tokensIds,
                data_.tokenIds[i],
                data_.amount0Min[i],
                data_.amount1Min[i],
                data_.hookData,
                data_.deadline
            );
        }
    }

    /// @notice Enters the Fuse using transient storage for parameters
    /// @dev Inputs: [0] currency0, [1] currency1, [2] fee, [3] tickSpacing, [4] hooks, [5] tickLower,
    ///      [6] tickUpper, [7] amount0Desired, [8] amount1Desired, [9] amount0Max, [10] amount1Max,
    ///      [11] deadline. hookData is always empty in the transient variant.
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        UniswapV4NewPositionFuseEnterData memory data_;
        data_.poolKey = PoolKey({
            currency0: Currency.wrap(TypeConversionLib.toAddress(inputs[0])),
            currency1: Currency.wrap(TypeConversionLib.toAddress(inputs[1])),
            fee: uint24(TypeConversionLib.toUint256(inputs[2])),
            tickSpacing: int24(TypeConversionLib.toInt256(inputs[3])),
            hooks: IHooks(TypeConversionLib.toAddress(inputs[4]))
        });
        data_.tickLower = int24(TypeConversionLib.toInt256(inputs[5]));
        data_.tickUpper = int24(TypeConversionLib.toInt256(inputs[6]));
        data_.amount0Desired = TypeConversionLib.toUint256(inputs[7]);
        data_.amount1Desired = TypeConversionLib.toUint256(inputs[8]);
        data_.amount0Max = TypeConversionLib.toUint256(inputs[9]);
        data_.amount1Max = TypeConversionLib.toUint256(inputs[10]);
        data_.hookData = bytes("");
        data_.deadline = TypeConversionLib.toUint256(inputs[11]);

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = enter(data_);

        bytes32[] memory outputs = new bytes32[](4);
        outputs[0] = TypeConversionLib.toBytes32(tokenId);
        outputs[1] = TypeConversionLib.toBytes32(uint256(liquidity));
        outputs[2] = TypeConversionLib.toBytes32(amount0);
        outputs[3] = TypeConversionLib.toBytes32(amount1);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits the Fuse using transient storage for parameters
    /// @dev Inputs: [0] length n, [1..n] tokenIds, [n+1..2n] amount0Min, [2n+1..3n] amount1Min,
    ///      [3n+1] deadline. hookData is always empty in the transient variant.
    function exitTransient() external {
        uint256 len = TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, 0));

        bytes32[] memory outputs = new bytes32[](1);

        if (len == 0) {
            outputs[0] = TypeConversionLib.toBytes32(uint256(0));
            TransientStorageLib.setOutputs(VERSION, outputs);
            return;
        }

        uint256[] memory tokenIds = new uint256[](len);
        uint256[] memory amount0Min = new uint256[](len);
        uint256[] memory amount1Min = new uint256[](len);

        for (uint256 i; i < len; ++i) {
            tokenIds[i] = TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, i + 1));
            amount0Min[i] = TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, len + i + 1));
            amount1Min[i] = TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, 2 * len + i + 1));
        }

        uint256[] memory returnedTokenIds = exit(
            UniswapV4NewPositionFuseExitData({
                tokenIds: tokenIds,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                hookData: bytes(""),
                deadline: TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, 3 * len + 1))
            })
        );

        outputs[0] = TypeConversionLib.toBytes32(returnedTokenIds.length);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    function _mintPosition(
        UniswapV4NewPositionFuseEnterData memory data_,
        uint128 liquidity_
    ) private returns (uint256 amount0, uint256 amount1) {
        address token0 = Currency.unwrap(data_.poolKey.currency0);
        address token1 = Currency.unwrap(data_.poolKey.currency1);

        _approvePermit2(token0, data_.amount0Max);
        _approvePermit2(token1, data_.amount1Max);

        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            data_.poolKey,
            data_.tickLower,
            data_.tickUpper,
            uint256(liquidity_),
            data_.amount0Max.toUint128(),
            data_.amount1Max.toUint128(),
            address(this),
            data_.hookData
        );
        params[1] = abi.encode(data_.poolKey.currency0, data_.poolKey.currency1);

        IPositionManagerV4(POSITION_MANAGER).modifyLiquidities(
            abi.encode(abi.encodePacked(ActionsV4.MINT_POSITION, ActionsV4.SETTLE_PAIR), params),
            data_.deadline
        );

        _resetPermit2(token0);
        _resetPermit2(token1);

        amount0 = balance0Before - IERC20(token0).balanceOf(address(this));
        amount1 = balance1Before - IERC20(token1).balanceOf(address(this));
    }

    function _emitEnter(
        UniswapV4NewPositionFuseEnterData memory data_,
        uint256 tokenId_,
        uint128 liquidity_,
        uint256 amount0_,
        uint256 amount1_
    ) private {
        emit UniswapV4NewPositionFuseEnter(
            VERSION,
            tokenId_,
            liquidity_,
            amount0_,
            amount1_,
            UniswapV4SubstrateLib.poolKeyToId(data_.poolKey),
            data_.tickLower,
            data_.tickUpper
        );
    }

    function _calculateLiquidity(UniswapV4NewPositionFuseEnterData memory data_) private view returns (uint128) {
        (uint160 sqrtPriceX96, , , ) = POOL_MANAGER.getSlot0(data_.poolKey.toId());

        return
            LiquidityAmountsV4.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(data_.tickLower),
                TickMath.getSqrtPriceAtTick(data_.tickUpper),
                data_.amount0Desired,
                data_.amount1Desired
            );
    }

    function _exitSingle(
        FuseStorageLib.UniswapV4TokenIds storage tokensIds_,
        uint256 tokenId_,
        uint256 amount0Min_,
        uint256 amount1Min_,
        bytes memory hookData_,
        uint256 deadline_
    ) private {
        /// @dev Only tokenIds registered by this fuse's enter can be closed; prevents storage corruption
        /// for NFTs transferred to the vault outside of the fuse.
        uint256 index = tokensIds_.indexes[tokenId_];
        uint256 storedLen = tokensIds_.tokenIds.length;

        if (index >= storedLen || tokensIds_.tokenIds[index] != tokenId_) {
            revert UniswapV4NewPositionFuseTokenIdNotTracked(tokenId_);
        }

        (PoolKey memory poolKey, ) = IPositionManagerV4(POSITION_MANAGER).getPoolAndPositionInfo(tokenId_);

        (uint256 amount0, uint256 amount1) = _burnPosition(
            poolKey,
            tokenId_,
            amount0Min_,
            amount1Min_,
            hookData_,
            deadline_
        );

        _removeTokenId(tokensIds_, tokenId_, index, storedLen);

        emit UniswapV4NewPositionFuseExit(VERSION, tokenId_, amount0, amount1);
    }

    function _burnPosition(
        PoolKey memory poolKey_,
        uint256 tokenId_,
        uint256 amount0Min_,
        uint256 amount1Min_,
        bytes memory hookData_,
        uint256 deadline_
    ) private returns (uint256 amount0, uint256 amount1) {
        address token0 = Currency.unwrap(poolKey_.currency0);
        address token1 = Currency.unwrap(poolKey_.currency1);

        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId_, amount0Min_.toUint128(), amount1Min_.toUint128(), hookData_);
        params[1] = abi.encode(poolKey_.currency0, poolKey_.currency1, address(this));

        IPositionManagerV4(POSITION_MANAGER).modifyLiquidities(
            abi.encode(abi.encodePacked(ActionsV4.BURN_POSITION, ActionsV4.TAKE_PAIR), params),
            deadline_
        );

        amount0 = IERC20(token0).balanceOf(address(this)) - balance0Before;
        amount1 = IERC20(token1).balanceOf(address(this)) - balance1Before;
    }

    function _removeTokenId(
        FuseStorageLib.UniswapV4TokenIds storage tokensIds_,
        uint256 tokenId_,
        uint256 index_,
        uint256 storedLen_
    ) private {
        uint256 lastIndex = storedLen_ - 1;

        if (index_ != lastIndex) {
            uint256 lastTokenId = tokensIds_.tokenIds[lastIndex];
            tokensIds_.tokenIds[index_] = lastTokenId;
            tokensIds_.indexes[lastTokenId] = index_;
        }

        tokensIds_.tokenIds.pop();
        delete tokensIds_.indexes[tokenId_];
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

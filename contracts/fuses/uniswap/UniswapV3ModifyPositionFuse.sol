// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {INonfungiblePositionManager} from "./ext/INonfungiblePositionManager.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";

/// @notice Data for entering UniswapV3ModifyPositionFuse.sol - increase liquidity
struct UniswapV3ModifyPositionFuseEnterData {
    /// @notice The address of the token0 for a specific pool
    address token0;
    /// @notice The address of the token1 for a specific pool
    address token1;
    /// @notice tokenId The ID of the token that represents the minted position
    uint256 tokenId;
    /// @notice The desired amount of token0 to be spent
    uint256 amount0Desired;
    /// @notice The desired amount of token1 to be spent
    uint256 amount1Desired;
    /// @notice The minimum amount of token0 to spend, which serves as a slippage check
    uint256 amount0Min;
    /// @notice The minimum amount of token1 to spend, which serves as a slippage check
    uint256 amount1Min;
    /// @notice The time by which the transaction must be included to effect the change
    uint256 deadline;
}

/// @notice Data for exiting UniswapV3ModifyPositionFuse.sol - decrease liquidity
struct UniswapV3ModifyPositionFuseExitData {
    /// @notice tokenId The ID of the token for which liquidity is being decreased
    uint256 tokenId;
    /// @notice The amount by which liquidity will be decreased
    uint128 liquidity;
    /// @notice The minimum amount of token0 that should be accounted for the burned liquidity
    uint256 amount0Min;
    /// @notice The minimum amount of token1 that should be accounted for the burned liquidity
    uint256 amount1Min;
    /// @notice The time by which the transaction must be included to effect the change
    uint256 deadline;
}

/// @title UniswapV3ModifyPositionFuse
/// @notice Fuse for modifying existing Uniswap V3 liquidity positions
/// @dev This fuse allows the PlasmaVault to increase or decrease liquidity in existing Uniswap V3 positions.
///      It supports both adding liquidity (enter) and removing liquidity (exit) from positions.
///      Associated with fuse balance UniswapV3Balance.
contract UniswapV3ModifyPositionFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    event UniswapV3ModifyPositionFuseEnter(
        address version,
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );
    event UniswapV3ModifyPositionFuseExit(address version, uint256 tokenId, uint256 amount0, uint256 amount1);

    error UniswapV3ModifyPositionFuseUnsupportedToken(address token0, address token1);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    /// @dev Manage NFTs representing liquidity positions
    address public immutable NONFUNGIBLE_POSITION_MANAGER;

    constructor(uint256 marketId_, address nonfungiblePositionManager_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
    }

    /// @notice Increases liquidity for an existing Uniswap V3 position
    /// @param data_ The data structure containing the parameters for increasing liquidity
    /// @return tokenId The ID of the token that represents the position
    /// @return liquidity The amount of liquidity added
    /// @return amount0 The amount of token0 added
    /// @return amount1 The amount of token1 added
    function enter(
        UniswapV3ModifyPositionFuseEnterData memory data_
    ) public returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        if (
            !PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.token0) ||
            !PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.token1)
        ) {
            revert UniswapV3ModifyPositionFuseUnsupportedToken(data_.token0, data_.token1);
        }

        IERC20(data_.token0).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), data_.amount0Desired);
        IERC20(data_.token1).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), data_.amount1Desired);

        INonfungiblePositionManager.IncreaseLiquidityParams memory params = INonfungiblePositionManager
            .IncreaseLiquidityParams({
                tokenId: data_.tokenId,
                amount0Desired: data_.amount0Desired,
                amount1Desired: data_.amount1Desired,
                amount0Min: data_.amount0Min,
                amount1Min: data_.amount1Min,
                deadline: data_.deadline
            });

        // Note that the pool defined by token0/token1 and fee tier must already be created and initialized in order to mint
        (liquidity, amount0, amount1) = INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER).increaseLiquidity(
            params
        );

        tokenId = data_.tokenId;

        IERC20(data_.token0).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), 0);
        IERC20(data_.token1).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), 0);

        emit UniswapV3ModifyPositionFuseEnter(VERSION, tokenId, liquidity, amount0, amount1);
    }

    /// @notice Decreases liquidity for an existing Uniswap V3 position
    /// @param data_ The data structure containing the parameters for decreasing liquidity
    /// @return tokenId The ID of the token for which liquidity was decreased
    /// @return amount0 The amount of token0 received
    /// @return amount1 The amount of token1 received
    function exit(
        UniswapV3ModifyPositionFuseExitData memory data_
    ) public returns (uint256 tokenId, uint256 amount0, uint256 amount1) {
        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager
            .DecreaseLiquidityParams({
                tokenId: data_.tokenId,
                liquidity: data_.liquidity,
                amount0Min: data_.amount0Min,
                amount1Min: data_.amount1Min,
                deadline: data_.deadline
            });

        /// @dev This method doesn't transfer the liquidity to the caller
        (amount0, amount1) = INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER).decreaseLiquidity(params);

        tokenId = data_.tokenId;

        emit UniswapV3ModifyPositionFuseExit(VERSION, tokenId, amount0, amount1);
    }

    /// @notice Enters the Fuse using transient storage for parameters
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        address token0 = TypeConversionLib.toAddress(inputs[0]);
        address token1 = TypeConversionLib.toAddress(inputs[1]);
        uint256 tokenId = TypeConversionLib.toUint256(inputs[2]);
        uint256 amount0Desired = TypeConversionLib.toUint256(inputs[3]);
        uint256 amount1Desired = TypeConversionLib.toUint256(inputs[4]);
        uint256 amount0Min = TypeConversionLib.toUint256(inputs[5]);
        uint256 amount1Min = TypeConversionLib.toUint256(inputs[6]);
        uint256 deadline = TypeConversionLib.toUint256(inputs[7]);

        (uint256 returnedTokenId, uint128 returnedLiquidity, uint256 returnedAmount0, uint256 returnedAmount1) = enter(
            UniswapV3ModifyPositionFuseEnterData({
                token0: token0,
                token1: token1,
                tokenId: tokenId,
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: deadline
            })
        );

        bytes32[] memory outputs = new bytes32[](4);
        outputs[0] = TypeConversionLib.toBytes32(returnedTokenId);
        outputs[1] = TypeConversionLib.toBytes32(uint256(returnedLiquidity));
        outputs[2] = TypeConversionLib.toBytes32(returnedAmount0);
        outputs[3] = TypeConversionLib.toBytes32(returnedAmount1);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits the Fuse using transient storage for parameters
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        uint256 tokenId = TypeConversionLib.toUint256(inputs[0]);
        uint128 liquidity = TypeConversionLib.toUint128(TypeConversionLib.toUint256(inputs[1]));
        uint256 amount0Min = TypeConversionLib.toUint256(inputs[2]);
        uint256 amount1Min = TypeConversionLib.toUint256(inputs[3]);
        uint256 deadline = TypeConversionLib.toUint256(inputs[4]);

        (uint256 returnedTokenId, uint256 returnedAmount0, uint256 returnedAmount1) = exit(
            UniswapV3ModifyPositionFuseExitData({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: amount0Min,
                amount1Min: amount1Min,
                deadline: deadline
            })
        );

        bytes32[] memory outputs = new bytes32[](3);
        outputs[0] = TypeConversionLib.toBytes32(returnedTokenId);
        outputs[1] = TypeConversionLib.toBytes32(returnedAmount0);
        outputs[2] = TypeConversionLib.toBytes32(returnedAmount1);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}

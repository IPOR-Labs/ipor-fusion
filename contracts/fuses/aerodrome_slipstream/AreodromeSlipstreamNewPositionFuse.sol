// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {INonfungiblePositionManager} from "./ext/INonfungiblePositionManager.sol";
import {AreodromeSlipstreamSubstrateLib, AreodromeSlipstreamSubstrateType, AreodromeSlipstreamSubstrate} from "./AreodromeSlipstreamLib.sol";

struct AreodromeSlipstreamNewPositionFuseEnterData {
    /// @notice The address of the token0 for a specific pool
    address token0;
    /// @notice The address of the token1 for a specific pool
    address token1;
    int24 tickSpacing;
    /// @notice The lower end of the tick range for the position
    int24 tickLower;
    /// @notice The higher end of the tick range for the position
    int24 tickUpper;
    /// @notice The amount of token0 desired to be spent
    uint256 amount0Desired;
    /// @notice The amount of token1 desired to be spent
    uint256 amount1Desired;
    /// @notice The minimum amount of token0 to spend, which serves as a slippage check
    uint256 amount0Min;
    /// @notice The minimum amount of token1 to spend, which serves as a slippage check
    uint256 amount1Min;
    /// @notice Deadline for the transaction
    uint256 deadline;
    uint160 sqrtPriceX96;
}

struct AreodromeSlipstreamNewPositionFuseExitData {
    uint256[] tokenIds;
}

contract AreodromeSlipstreamNewPositionFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    error AreodromeSlipstreamNewPositionFuseUnsupportedPool(address pool);
    error InvalidAddress();
    error InvalidAmount();

    event AreodromeSlipstreamNewPositionFuseEnter(
        address version,
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1,
        address token0,
        address token1,
        int24 tickSpacing,
        int24 tickLower,
        int24 tickUpper
    );

    event AreodromeSlipstreamNewPositionFuseExit(address version, uint256 tokenId);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable NONFUNGIBLE_POSITION_MANAGER;
    address public immutable FACTORY;

    constructor(uint256 marketId_, address nonfungiblePositionManager_) {
        if (nonfungiblePositionManager_ == address(0)) {
            revert InvalidAddress();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
        FACTORY = INonfungiblePositionManager(nonfungiblePositionManager_).factory();

        if (FACTORY == address(0)) {
            revert InvalidAddress();
        }
    }

    /// @notice Creates a new NFT position
    /// @dev Validates the pool, approves tokens, mints position, and resets approvals
    /// @param data_ The data containing token addresses, tick parameters, amounts, and deadline
    /// @return tokenId The ID of the newly minted token
    /// @return liquidity The amount of liquidity added
    /// @return amount0 The amount of token0 used
    /// @return amount1 The amount of token1 used
    function enter(
        AreodromeSlipstreamNewPositionFuseEnterData memory data_
    ) public returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        {
            if (
                !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                    MARKET_ID,
                    AreodromeSlipstreamSubstrateLib.substrateToBytes32(
                        AreodromeSlipstreamSubstrate({
                            substrateType: AreodromeSlipstreamSubstrateType.Pool,
                            substrateAddress: AreodromeSlipstreamSubstrateLib.getPoolAddress(
                                FACTORY,
                                data_.token0,
                                data_.token1,
                                data_.tickSpacing
                            )
                        })
                    )
                )
            ) {
                /// @dev this is to avoid stack too deep error
                revert AreodromeSlipstreamNewPositionFuseUnsupportedPool(
                    AreodromeSlipstreamSubstrateLib.getPoolAddress(
                        FACTORY,
                        data_.token0,
                        data_.token1,
                        data_.tickSpacing
                    )
                );
            }
        }

        if (data_.amount0Desired > 0) {
            IERC20(data_.token0).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), data_.amount0Desired);
        }

        if (data_.amount1Desired > 0) {
            IERC20(data_.token1).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), data_.amount1Desired);
        }

        (tokenId, liquidity, amount0, amount1) = INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER).mint(
            INonfungiblePositionManager.MintParams({
                token0: data_.token0,
                token1: data_.token1,
                tickSpacing: data_.tickSpacing,
                tickLower: data_.tickLower,
                tickUpper: data_.tickUpper,
                amount0Desired: data_.amount0Desired,
                amount1Desired: data_.amount1Desired,
                amount0Min: data_.amount0Min,
                amount1Min: data_.amount1Min,
                recipient: address(this),
                deadline: data_.deadline,
                sqrtPriceX96: data_.sqrtPriceX96
            })
        );

        IERC20(data_.token0).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), 0);
        IERC20(data_.token1).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), 0);

        emit AreodromeSlipstreamNewPositionFuseEnter(
            VERSION,
            tokenId,
            liquidity,
            amount0,
            amount1,
            data_.token0,
            data_.token1,
            data_.tickSpacing,
            data_.tickLower,
            data_.tickUpper
        );
    }

    /// @notice Creates a new NFT position using transient storage for inputs
    /// @dev Reads all parameters from transient storage
    /// @dev Writes returned tokenId, liquidity, amount0, amount1 to transient storage outputs
    function enterTransient() external {
        bytes32 token0Bytes32 = TransientStorageLib.getInput(VERSION, 0);
        bytes32 token1Bytes32 = TransientStorageLib.getInput(VERSION, 1);
        bytes32 tickSpacingBytes32 = TransientStorageLib.getInput(VERSION, 2);
        bytes32 tickLowerBytes32 = TransientStorageLib.getInput(VERSION, 3);
        bytes32 tickUpperBytes32 = TransientStorageLib.getInput(VERSION, 4);
        bytes32 amount0DesiredBytes32 = TransientStorageLib.getInput(VERSION, 5);
        bytes32 amount1DesiredBytes32 = TransientStorageLib.getInput(VERSION, 6);
        bytes32 amount0MinBytes32 = TransientStorageLib.getInput(VERSION, 7);
        bytes32 amount1MinBytes32 = TransientStorageLib.getInput(VERSION, 8);
        bytes32 deadlineBytes32 = TransientStorageLib.getInput(VERSION, 9);
        bytes32 sqrtPriceX96Bytes32 = TransientStorageLib.getInput(VERSION, 10);

        address token0 = TypeConversionLib.toAddress(token0Bytes32);
        address token1 = TypeConversionLib.toAddress(token1Bytes32);
        int24 tickSpacing = int24(int256(TypeConversionLib.toUint256(tickSpacingBytes32)));
        int24 tickLower = int24(int256(TypeConversionLib.toUint256(tickLowerBytes32)));
        int24 tickUpper = int24(int256(TypeConversionLib.toUint256(tickUpperBytes32)));
        uint256 amount0Desired = TypeConversionLib.toUint256(amount0DesiredBytes32);
        uint256 amount1Desired = TypeConversionLib.toUint256(amount1DesiredBytes32);
        uint256 amount0Min = TypeConversionLib.toUint256(amount0MinBytes32);
        uint256 amount1Min = TypeConversionLib.toUint256(amount1MinBytes32);
        uint256 deadline = TypeConversionLib.toUint256(deadlineBytes32);
        uint160 sqrtPriceX96 = uint160(TypeConversionLib.toUint256(sqrtPriceX96Bytes32));

        AreodromeSlipstreamNewPositionFuseEnterData memory data = AreodromeSlipstreamNewPositionFuseEnterData({
            token0: token0,
            token1: token1,
            tickSpacing: tickSpacing,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            deadline: deadline,
            sqrtPriceX96: sqrtPriceX96
        });

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = enter(data);

        bytes32[] memory outputs = new bytes32[](4);
        outputs[0] = TypeConversionLib.toBytes32(tokenId);
        outputs[1] = TypeConversionLib.toBytes32(uint256(liquidity));
        outputs[2] = TypeConversionLib.toBytes32(amount0);
        outputs[3] = TypeConversionLib.toBytes32(amount1);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Burns NFT positions
    /// @dev Burns all token IDs in the provided array
    /// @param closePositions The data containing array of token IDs to burn
    /// @return tokenIds The array of burned token IDs
    function exit(
        AreodromeSlipstreamNewPositionFuseExitData memory closePositions
    ) public returns (uint256[] memory tokenIds) {
        uint256 len = closePositions.tokenIds.length;

        if (len == 0) {
            return new uint256[](0);
        }

        for (uint256 i; i < len; i++) {
            INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER).burn(closePositions.tokenIds[i]);

            emit AreodromeSlipstreamNewPositionFuseExit(VERSION, closePositions.tokenIds[i]);
        }

        return closePositions.tokenIds;
    }

    /// @notice Burns NFT positions using transient storage for inputs
    /// @dev Reads tokenIds array from transient storage (first element is length, subsequent elements are tokenIds)
    /// @dev Writes returned tokenIds array length to transient storage outputs
    function exitTransient() external {
        bytes32 lengthBytes32 = TransientStorageLib.getInput(VERSION, 0);
        uint256 len = TypeConversionLib.toUint256(lengthBytes32);

        if (len == 0) {
            bytes32[] memory outputs = new bytes32[](1);
            outputs[0] = TypeConversionLib.toBytes32(uint256(0));
            TransientStorageLib.setOutputs(VERSION, outputs);
            return;
        }

        uint256[] memory tokenIds = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            bytes32 tokenIdBytes32 = TransientStorageLib.getInput(VERSION, i + 1);
            tokenIds[i] = TypeConversionLib.toUint256(tokenIdBytes32);
        }

        AreodromeSlipstreamNewPositionFuseExitData memory data = AreodromeSlipstreamNewPositionFuseExitData({
            tokenIds: tokenIds
        });

        uint256[] memory returnedTokenIds = exit(data);

        bytes32[] memory outputs = new bytes32[](1);
        outputs[0] = TypeConversionLib.toBytes32(returnedTokenIds.length);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}

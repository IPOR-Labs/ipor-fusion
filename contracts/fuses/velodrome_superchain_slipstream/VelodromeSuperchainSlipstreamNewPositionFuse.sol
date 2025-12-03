// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {INonfungiblePositionManager} from "./ext/INonfungiblePositionManager.sol";
import {VelodromeSuperchainSlipstreamSubstrateLib, VelodromeSuperchainSlipstreamSubstrateType, VelodromeSuperchainSlipstreamSubstrate} from "./VelodromeSuperchainSlipstreamSubstrateLib.sol";

struct VelodromeSuperchainSlipstreamNewPositionFuseEnterData {
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

struct VelodromeSuperchainSlipstreamNewPositionFuseExitData {
    uint256[] tokenIds;
}

struct VelodromeSuperchainSlipstreamNewPositionFuseEnterResult {
    uint256 tokenId;
    uint128 liquidity;
    uint256 amount0;
    uint256 amount1;
    address token0;
    address token1;
    int24 tickSpacing;
    int24 tickLower;
    int24 tickUpper;
}

contract VelodromeSuperchainSlipstreamNewPositionFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    error VelodromeSuperchainSlipstreamNewPositionFuseUnsupportedPool(address pool);

    event VelodromeSuperchainSlipstreamNewPositionFuseEnter(
        address indexed version,
        uint256 indexed tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1,
        address token0,
        address token1,
        int24 tickSpacing,
        int24 tickLower,
        int24 tickUpper
    );

    event VelodromeSuperchainSlipstreamNewPositionFuseExit(address indexed version, uint256 indexed tokenId);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable NONFUNGIBLE_POSITION_MANAGER;
    address public immutable FACTORY;

    constructor(uint256 marketId_, address nonfungiblePositionManager_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
        FACTORY = INonfungiblePositionManager(nonfungiblePositionManager_).factory();
    }

    /// @notice Enters a new Velodrome Superchain Slipstream position
    /// @param data_ The data required to enter the position
    /// @return result The result containing tokenId, liquidity, amounts, tokens, and tick information
    function enter(
        VelodromeSuperchainSlipstreamNewPositionFuseEnterData memory data_
    ) public returns (VelodromeSuperchainSlipstreamNewPositionFuseEnterResult memory result) {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                VelodromeSuperchainSlipstreamSubstrateLib.substrateToBytes32(
                    VelodromeSuperchainSlipstreamSubstrate({
                        substrateType: VelodromeSuperchainSlipstreamSubstrateType.Pool,
                        substrateAddress: VelodromeSuperchainSlipstreamSubstrateLib.getPoolAddress(
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
            revert VelodromeSuperchainSlipstreamNewPositionFuseUnsupportedPool(
                VelodromeSuperchainSlipstreamSubstrateLib.getPoolAddress(
                    FACTORY,
                    data_.token0,
                    data_.token1,
                    data_.tickSpacing
                )
            );
        }

        IERC20(data_.token0).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), data_.amount0Desired);
        IERC20(data_.token1).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), data_.amount1Desired);

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = INonfungiblePositionManager(
            NONFUNGIBLE_POSITION_MANAGER
        ).mint(
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

        result.tokenId = tokenId;
        result.liquidity = liquidity;
        result.amount0 = amount0;
        result.amount1 = amount1;
        result.token0 = data_.token0;
        result.token1 = data_.token1;
        result.tickSpacing = data_.tickSpacing;
        result.tickLower = data_.tickLower;
        result.tickUpper = data_.tickUpper;

        emit VelodromeSuperchainSlipstreamNewPositionFuseEnter(
            VERSION,
            result.tokenId,
            result.liquidity,
            result.amount0,
            result.amount1,
            result.token0,
            result.token1,
            result.tickSpacing,
            result.tickLower,
            result.tickUpper
        );
    }

    /// @notice Exits one or more Velodrome Superchain Slipstream positions
    /// @param closePositions_ The data required to exit the positions
    /// @return tokenIds The array of token IDs that were closed
    function exit(
        VelodromeSuperchainSlipstreamNewPositionFuseExitData memory closePositions_
    ) public returns (uint256[] memory tokenIds) {
        uint256 len = closePositions_.tokenIds.length;
        tokenIds = new uint256[](len);

        for (uint256 i; i < len; ++i) {
            tokenIds[i] = closePositions_.tokenIds[i];
            INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER).burn(closePositions_.tokenIds[i]);

            emit VelodromeSuperchainSlipstreamNewPositionFuseExit(VERSION, closePositions_.tokenIds[i]);
        }
    }

    /// @notice Enters the Fuse using transient storage for parameters
    /// @dev Reads all parameters from transient storage and writes returned values to outputs
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        VelodromeSuperchainSlipstreamNewPositionFuseEnterData
            memory data_ = VelodromeSuperchainSlipstreamNewPositionFuseEnterData({
                token0: TypeConversionLib.toAddress(inputs[0]),
                token1: TypeConversionLib.toAddress(inputs[1]),
                tickSpacing: int24(TypeConversionLib.toInt256(inputs[2])),
                tickLower: int24(TypeConversionLib.toInt256(inputs[3])),
                tickUpper: int24(TypeConversionLib.toInt256(inputs[4])),
                amount0Desired: TypeConversionLib.toUint256(inputs[5]),
                amount1Desired: TypeConversionLib.toUint256(inputs[6]),
                amount0Min: TypeConversionLib.toUint256(inputs[7]),
                amount1Min: TypeConversionLib.toUint256(inputs[8]),
                deadline: TypeConversionLib.toUint256(inputs[9]),
                sqrtPriceX96: uint160(TypeConversionLib.toUint256(inputs[10]))
            });

        VelodromeSuperchainSlipstreamNewPositionFuseEnterResult memory result = enter(data_);

        bytes32[] memory outputs = new bytes32[](9);
        outputs[0] = TypeConversionLib.toBytes32(result.tokenId);
        outputs[1] = TypeConversionLib.toBytes32(uint256(result.liquidity));
        outputs[2] = TypeConversionLib.toBytes32(result.amount0);
        outputs[3] = TypeConversionLib.toBytes32(result.amount1);
        outputs[4] = TypeConversionLib.toBytes32(result.token0);
        outputs[5] = TypeConversionLib.toBytes32(result.token1);
        outputs[6] = TypeConversionLib.toBytes32(uint256(int256(result.tickSpacing)));
        outputs[7] = TypeConversionLib.toBytes32(uint256(int256(result.tickLower)));
        outputs[8] = TypeConversionLib.toBytes32(uint256(int256(result.tickUpper)));
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits the Fuse using transient storage for parameters
    /// @dev Reads tokenIds array from transient storage (first element is length, subsequent elements are tokenIds)
    /// @dev Writes returned tokenIds array length to transient storage outputs
    function exitTransient() external {
        bytes32 lengthBytes32 = TransientStorageLib.getInput(VERSION, 0);
        uint256 len = TypeConversionLib.toUint256(lengthBytes32);

        bytes32[] memory outputs = new bytes32[](1);

        if (len == 0) {
            outputs[0] = TypeConversionLib.toBytes32(uint256(0));
            TransientStorageLib.setOutputs(VERSION, outputs);
            return;
        }

        uint256[] memory tokenIds = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            bytes32 tokenIdBytes32 = TransientStorageLib.getInput(VERSION, i + 1);
            tokenIds[i] = TypeConversionLib.toUint256(tokenIdBytes32);
        }

        uint256[] memory returnedTokenIds = exit(
            VelodromeSuperchainSlipstreamNewPositionFuseExitData({tokenIds: tokenIds})
        );

        outputs[0] = TypeConversionLib.toBytes32(returnedTokenIds.length);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}

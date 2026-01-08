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

/**
 * @title VelodromeSuperchainSlipstreamNewPositionFuse
 * @notice Fuse contract for creating and closing Velodrome Superchain Slipstream liquidity positions
 * @dev This contract allows the Plasma Vault to interact with Velodrome Superchain Slipstream protocol,
 *      enabling the creation of new NFT positions representing concentrated liquidity and the closing
 *      of existing positions. It validates pool substrates, handles token approvals using forceApprove
 *      pattern, and manages position lifecycle. Supports both standard and transient storage patterns
 *      for gas-efficient operations.
 * @author IPOR Labs
 */
contract VelodromeSuperchainSlipstreamNewPositionFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    error VelodromeSuperchainSlipstreamNewPositionFuseUnsupportedPool(address pool);
    error VelodromeSuperchainSlipstreamNewPositionFuseInvalidAddress();

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

    /**
     * @notice Initializes the VelodromeSuperchainSlipstreamNewPositionFuse with market ID and position manager
     * @param marketId_ The market ID used to identify the market and validate pool substrates
     * @param nonfungiblePositionManager_ The address of the Velodrome Superchain Slipstream NonfungiblePositionManager (must not be address(0))
     * @dev Reverts if nonfungiblePositionManager_ is zero address. Retrieves factory address from position manager.
     */
    constructor(uint256 marketId_, address nonfungiblePositionManager_) {
        if (nonfungiblePositionManager_ == address(0)) {
            revert VelodromeSuperchainSlipstreamNewPositionFuseInvalidAddress();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
        FACTORY = INonfungiblePositionManager(nonfungiblePositionManager_).factory();
    }

    /**
     * @notice Creates a new Velodrome Superchain Slipstream NFT position
     * @dev Validates that the pool is granted as a substrate, approves tokens using forceApprove pattern,
     *      mints a new position via the NonfungiblePositionManager, resets approvals, and emits an event.
     *      The position represents concentrated liquidity within a specified tick range.
     * @param data_ The enter data containing token addresses, tick parameters, amounts, slippage protection, and deadline
     * @return result The result containing tokenId, liquidity, actual amounts used, token addresses, and tick information
     * @custom:reverts VelodromeSuperchainSlipstreamNewPositionFuseUnsupportedPool If pool is not granted as a substrate
     */
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

    /**
     * @notice Closes one or more Velodrome Superchain Slipstream NFT positions
     * @dev Burns the specified NFT positions, which removes liquidity and returns tokens to the vault.
     *      Iterates through all provided token IDs and burns each position. Emits an event for each
     *      closed position.
     * @param closePositions_ The exit data containing array of token IDs to close
     * @return tokenIds The array of token IDs that were successfully closed
     */
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

    /**
     * @notice Enters the Fuse using transient storage for parameters
     * @dev Reads token0, token1, tickSpacing, tickLower, tickUpper, amount0Desired, amount1Desired,
     *      amount0Min, amount1Min, deadline, and sqrtPriceX96 from transient storage inputs,
     *      calls enter() with the decoded data, and writes the result (tokenId, liquidity, amount0,
     *      amount1, token0, token1, tickSpacing, tickLower, tickUpper) to transient storage outputs.
     *      Input 0: token0 (address)
     *      Input 1: token1 (address)
     *      Input 2: tickSpacing (int24)
     *      Input 3: tickLower (int24)
     *      Input 4: tickUpper (int24)
     *      Input 5: amount0Desired (uint256)
     *      Input 6: amount1Desired (uint256)
     *      Input 7: amount0Min (uint256)
     *      Input 8: amount1Min (uint256)
     *      Input 9: deadline (uint256)
     *      Input 10: sqrtPriceX96 (uint160)
     *      Output 0: tokenId (uint256)
     *      Output 1: liquidity (uint128 as uint256)
     *      Output 2: amount0 (uint256)
     *      Output 3: amount1 (uint256)
     *      Output 4: token0 (address)
     *      Output 5: token1 (address)
     *      Output 6: tickSpacing (int24 as uint256)
     *      Output 7: tickLower (int24 as uint256)
     *      Output 8: tickUpper (int24 as uint256)
     */
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

    /**
     * @notice Exits the Fuse using transient storage for parameters
     * @dev Reads tokenIds array from transient storage (first element is length, subsequent elements are tokenIds),
     *      calls exit() with the decoded data, and writes the returned tokenIds array length to transient storage outputs.
     *      Input 0: tokenIdsLength (uint256)
     *      Inputs 1 to tokenIdsLength: tokenIds (uint256[])
     *      Output 0: returnedTokenIdsLength (uint256)
     */
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

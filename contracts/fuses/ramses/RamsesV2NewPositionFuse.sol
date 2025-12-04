// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {INonfungiblePositionManagerRamses} from "./ext/INonfungiblePositionManagerRamses.sol";

/// @notice Data for entering new position in Ramses V2
struct RamsesV2NewPositionFuseEnterData {
    /// @notice The address of the token0 for a specific pool
    address token0;
    /// @notice The address of the token1 for a specific pool
    address token1;
    /// @notice The fee associated with the pool Ramses V2 pool
    uint24 fee;
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
    /// @notice The token ID of the RAM token
    uint256 veRamTokenId;
}

/// @notice Data for closing position on Uniswap V3
struct RamsesV2NewPositionFuseExitData {
    /// @notice Token IDs to close, NTFs minted on Uniswap V3, which represent liquidity positions
    uint256[] tokenIds;
}

/**
 * @title RamsesV2NewPositionFuse
 * @dev Contract for creating and managing new liquidity positions in the Ramses V2 system.
 */
contract RamsesV2NewPositionFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    /// @notice Event emitted when a new position is created
    /// @param version The address of the contract version
    /// @param tokenId The ID of the token
    /// @param liquidity The amount of liquidity added
    /// @param amount0 The amount of token0 added
    /// @param amount1 The amount of token1 added
    /// @param token0 The address of token0
    /// @param token1 The address of token1
    /// @param fee The fee associated with the pool
    /// @param tickLower The lower end of the tick range for the position
    /// @param tickUpper The higher end of the tick range for the position
    event RamsesV2NewPositionFuseEnter(
        address version,
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1,
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper
    );
    /// @notice Event emitted when a position is closed
    /// @param version The address of the contract version
    /// @param tokenId The ID of the token
    event RamsesV2NewPositionFuseExit(address version, uint256 tokenId);

    /// @notice Error thrown when unsupported tokens are used
    /// @param token0 The address of token0
    /// @param token1 The address of token1
    error RamsesV2NewPositionFuseUnsupportedToken(address token0, address token1);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable NONFUNGIBLE_POSITION_MANAGER;

    /**
     * @dev Constructor for the RamsesV2NewPositionFuse contract
     * @param marketId_ The ID of the market
     * @param nonfungiblePositionManager_ The address of the non-fungible position manager
     */
    constructor(uint256 marketId_, address nonfungiblePositionManager_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
    }

    /**
     * @notice Function to create a new liquidity position
     * @param data_ The data containing the parameters for creating a new position
     * @return tokenId The ID of the token
     * @return liquidity The amount of liquidity added
     * @return amount0 The amount of token0 added
     * @return amount1 The amount of token1 added
     * @return token0 The address of token0
     * @return token1 The address of token1
     * @return fee The fee associated with the pool
     * @return tickLower The lower end of the tick range for the position
     * @return tickUpper The higher end of the tick range for the position
     */
    function enter(
        RamsesV2NewPositionFuseEnterData memory data_
    )
        public
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper
        )
    {
        {
            if (
                !PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.token0) ||
                !PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.token1)
            ) {
                revert RamsesV2NewPositionFuseUnsupportedToken(data_.token0, data_.token1);
            }
        }

        IERC20(data_.token0).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), data_.amount0Desired);
        IERC20(data_.token1).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), data_.amount1Desired);

        (tokenId, liquidity, amount0, amount1) = _mint(data_);

        IERC20(data_.token0).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), 0);
        IERC20(data_.token1).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), 0);

        FuseStorageLib.RamsesV2TokenIds storage tokensIds = FuseStorageLib.getRamsesV2TokenIds();
        tokensIds.indexes[tokenId] = tokensIds.tokenIds.length;
        tokensIds.tokenIds.push(tokenId);

        token0 = data_.token0;
        token1 = data_.token1;
        fee = data_.fee;
        tickLower = data_.tickLower;
        tickUpper = data_.tickUpper;

        emit RamsesV2NewPositionFuseEnter(
            VERSION,
            tokenId,
            liquidity,
            amount0,
            amount1,
            token0,
            token1,
            fee,
            tickLower,
            tickUpper
        );
    }

    function _mint(
        RamsesV2NewPositionFuseEnterData memory data_
    ) private returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        INonfungiblePositionManagerRamses.MintParams memory params = INonfungiblePositionManagerRamses.MintParams({
            token0: data_.token0,
            token1: data_.token1,
            fee: data_.fee,
            tickLower: data_.tickLower,
            tickUpper: data_.tickUpper,
            amount0Desired: data_.amount0Desired,
            amount1Desired: data_.amount1Desired,
            amount0Min: data_.amount0Min,
            amount1Min: data_.amount1Min,
            recipient: address(this),
            deadline: data_.deadline,
            veRamTokenId: data_.veRamTokenId
        });
        return INonfungiblePositionManagerRamses(NONFUNGIBLE_POSITION_MANAGER).mint(params);
    }

    /**
     * @notice Function to close liquidity positions
     * @param closePositions The data containing the token IDs of the positions to close
     * @return tokenIds The array of token IDs that were closed
     */
    function exit(RamsesV2NewPositionFuseExitData memory closePositions) public returns (uint256[] memory tokenIds) {
        FuseStorageLib.RamsesV2TokenIds storage tokensIds = FuseStorageLib.getRamsesV2TokenIds();

        uint256 len = tokensIds.tokenIds.length;
        uint256 tokenIndex;

        tokenIds = closePositions.tokenIds;

        uint256 tokenId;
        uint256 lastTokenId;
        for (uint256 i; i < closePositions.tokenIds.length; ++i) {
            tokenId = closePositions.tokenIds[i];
            INonfungiblePositionManagerRamses(NONFUNGIBLE_POSITION_MANAGER).burn(tokenId);

            tokenIndex = tokensIds.indexes[tokenId];
            if (tokenIndex != len - 1) {
                lastTokenId = tokensIds.tokenIds[len - 1];
                tokensIds.tokenIds[tokenIndex] = lastTokenId;
                tokensIds.indexes[lastTokenId] = tokenIndex;
            }
            tokensIds.tokenIds.pop();
            delete tokensIds.indexes[tokenId];
            --len;

            emit RamsesV2NewPositionFuseExit(VERSION, tokenId);
        }
    }

    /// @notice Enters the Fuse using transient storage for parameters
    /// @dev Reads all parameters from transient storage and writes returned values to outputs
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        RamsesV2NewPositionFuseEnterData memory data_ = RamsesV2NewPositionFuseEnterData({
            token0: TypeConversionLib.toAddress(inputs[0]),
            token1: TypeConversionLib.toAddress(inputs[1]),
            fee: uint24(TypeConversionLib.toUint256(inputs[2])),
            tickLower: int24(TypeConversionLib.toInt256(inputs[3])),
            tickUpper: int24(TypeConversionLib.toInt256(inputs[4])),
            amount0Desired: TypeConversionLib.toUint256(inputs[5]),
            amount1Desired: TypeConversionLib.toUint256(inputs[6]),
            amount0Min: TypeConversionLib.toUint256(inputs[7]),
            amount1Min: TypeConversionLib.toUint256(inputs[8]),
            deadline: TypeConversionLib.toUint256(inputs[9]),
            veRamTokenId: TypeConversionLib.toUint256(inputs[10])
        });

        (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1,
            address returnedToken0,
            address returnedToken1,
            uint24 returnedFee,
            int24 returnedTickLower,
            int24 returnedTickUpper
        ) = enter(data_);

        bytes32[] memory outputs = new bytes32[](9);
        outputs[0] = TypeConversionLib.toBytes32(tokenId);
        outputs[1] = TypeConversionLib.toBytes32(uint256(liquidity));
        outputs[2] = TypeConversionLib.toBytes32(amount0);
        outputs[3] = TypeConversionLib.toBytes32(amount1);
        outputs[4] = TypeConversionLib.toBytes32(returnedToken0);
        outputs[5] = TypeConversionLib.toBytes32(returnedToken1);
        outputs[6] = TypeConversionLib.toBytes32(uint256(returnedFee));
        outputs[7] = TypeConversionLib.toBytes32(uint256(int256(returnedTickLower)));
        outputs[8] = TypeConversionLib.toBytes32(uint256(int256(returnedTickUpper)));
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

        uint256[] memory returnedTokenIds = exit(RamsesV2NewPositionFuseExitData({tokenIds: tokenIds}));

        outputs[0] = TypeConversionLib.toBytes32(returnedTokenIds.length);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}

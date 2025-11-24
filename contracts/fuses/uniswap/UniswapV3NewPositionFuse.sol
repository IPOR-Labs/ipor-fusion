// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {INonfungiblePositionManager, IUniswapV3Factory, IUniswapV3Pool} from "./ext/INonfungiblePositionManager.sol";
import {PositionValue} from "./ext/PositionValue.sol";

/// @notice Data for entering new position in Uniswap V3
struct UniswapV3NewPositionFuseEnterData {
    /// @notice The address of the token0 for a specific pool
    address token0;
    /// @notice The address of the token1 for a specific pool
    address token1;
    /// @notice The fee associated with the pool Uniswap V3 pool, 0,05%, 0,3% or 1%
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
}

/// @notice Data for closing position on Uniswap V3
struct UniswapV3NewPositionFuseExitData {
    /// @notice Token IDs to close, NTFs minted on Uniswap V3, which represent liquidity positions
    uint256[] tokenIds;
}

/// @title Fuse responsible for create new Uniswap V3 positions.
/// @dev Associated with fuse balance UniswapV3Balance.
contract UniswapV3NewPositionFuse is IFuseCommon {
    using SafeERC20 for IERC20;
    using Address for address;

    error InvalidReturnData();

    event UniswapV3NewPositionFuseEnter(
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

    event UniswapV3NewPositionFuseExit(address version, uint256 tokenIds);

    error UniswapV3NewPositionFuseUnsupportedToken(address token0, address token1);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable NONFUNGIBLE_POSITION_MANAGER;

    constructor(uint256 marketId_, address nonfungiblePositionManager_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
    }

    /// @notice Enters a new Uniswap V3 position.
    /// @param data_ The data required to enter the new position.
    function enter(UniswapV3NewPositionFuseEnterData calldata data_) public {
        if (
            !PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.token0) ||
            !PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.token1)
        ) {
            revert UniswapV3NewPositionFuseUnsupportedToken(data_.token0, data_.token1);
        }

        IERC20(data_.token0).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), data_.amount0Desired);
        IERC20(data_.token1).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), data_.amount1Desired);

        // Note that the pool defined by token0/token1 and fee tier must already be created and initialized in order to mint
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = INonfungiblePositionManager(
            NONFUNGIBLE_POSITION_MANAGER
        ).mint(
                /// @dev The values for tickLower and tickUpper may not work for all tick spacings. Setting amount0Min and amount1Min to 0 is unsafe.
                INonfungiblePositionManager.MintParams({
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
                    deadline: data_.deadline
                })
            );

        IERC20(data_.token0).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), 0);
        IERC20(data_.token1).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), 0);

        FuseStorageLib.UniswapV3TokenIds storage tokensIds = FuseStorageLib.getUniswapV3TokenIds();
        tokensIds.indexes[tokenId] = tokensIds.tokenIds.length;
        tokensIds.tokenIds.push(tokenId);

        emit UniswapV3NewPositionFuseEnter(
            VERSION,
            tokenId,
            liquidity,
            amount0,
            amount1,
            data_.token0,
            data_.token1,
            data_.fee,
            data_.tickLower,
            data_.tickUpper
        );
    }

    /// @notice Exits one or more Uniswap V3 positions.
    /// @param closePositions The data required to exit the positions.
    function exit(UniswapV3NewPositionFuseExitData calldata closePositions) public {
        FuseStorageLib.UniswapV3TokenIds storage tokensIds = FuseStorageLib.getUniswapV3TokenIds();

        uint256 len = tokensIds.tokenIds.length;
        uint256 tokenIndex;

        for (uint256 i; i < len; i++) {
            if (!_canExit(closePositions.tokenIds[i])) {
                continue;
            }

            INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER).burn(closePositions.tokenIds[i]);

            tokenIndex = tokensIds.indexes[closePositions.tokenIds[i]];
            if (tokenIndex != len - 1) {
                tokensIds.tokenIds[tokenIndex] = tokensIds.tokenIds[len - 1];
            }
            tokensIds.tokenIds.pop();

            emit UniswapV3NewPositionFuseExit(VERSION, closePositions.tokenIds[i]);
        }
    }

    /// @notice Extracts token0, token1, and fee from a position using assembly for gas optimization.
    /// @param tokenId_ The ID of the token that represents the position
    /// @return token0 The address of the token0 for a specific pool
    /// @return token1 The address of the token1 for a specific pool
    /// @return fee The fee associated with the pool
    function getPositionInfo(uint256 tokenId_) private view returns (address token0, address token1, uint24 fee) {
        bytes memory returnData = NONFUNGIBLE_POSITION_MANAGER.functionStaticCall(
            abi.encodeWithSelector(INonfungiblePositionManager.positions.selector, tokenId_)
        );

        if (returnData.length < 160) revert InvalidReturnData();

        assembly {
            token0 := mload(add(returnData, 96))
            token1 := mload(add(returnData, 128))
            let feeValue := mload(add(returnData, 160))
            fee := and(feeValue, 0xFFFFFF)
        }
    }

    /// @notice Gets sqrtPriceX96 from a pool using assembly for gas optimization.
    /// @param factory_ The Uniswap V3 factory address
    /// @param token0_ The address of the token0 for a specific pool
    /// @param token1_ The address of the token1 for a specific pool
    /// @param fee_ The fee associated with the pool
    /// @return sqrtPriceX96 The current price of the pool as a sqrt(token1/token0) Q64.96 value
    function getSqrtPriceX96(
        address factory_,
        address token0_,
        address token1_,
        uint24 fee_
    ) private view returns (uint160 sqrtPriceX96) {
        address pool = IUniswapV3Factory(factory_).getPool(token0_, token1_, fee_);

        bytes memory returnData = pool.functionStaticCall(abi.encodeWithSelector(IUniswapV3Pool.slot0.selector));

        if (returnData.length < 64) revert InvalidReturnData();

        assembly {
            let sqrtPriceValue := mload(add(returnData, 32))
            sqrtPriceX96 := and(sqrtPriceValue, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
        }
    }

    function _canExit(uint256 tokenId) private view returns (bool) {
        (address token0, address token1, uint24 fee) = getPositionInfo(tokenId);

        address factory = INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER).factory();

        uint160 sqrtPriceX96 = getSqrtPriceX96(factory, token0, token1, fee);

        (uint256 amount0, uint256 amount1) = PositionValue.total(
            INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER),
            tokenId,
            sqrtPriceX96
        );

        return amount0 < IERC20Metadata(token0).decimals() / 2 && amount1 < IERC20Metadata(token1).decimals() / 2;
    }
}

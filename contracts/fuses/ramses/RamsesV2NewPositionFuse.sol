// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {INonfungiblePositionManagerRamses} from "./ext/INonfungiblePositionManagerRamses.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";

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
     */
    function enter(RamsesV2NewPositionFuseEnterData calldata data_) public {
        if (
            !PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.token0) ||
            !PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.token1)
        ) {
            revert RamsesV2NewPositionFuseUnsupportedToken(data_.token0, data_.token1);
        }

        IERC20(data_.token0).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), data_.amount0Desired);
        IERC20(data_.token1).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), data_.amount1Desired);

        // Note that the pool defined by token0/token1 and fee tier must already be created and initialized in order to mint
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = INonfungiblePositionManagerRamses(
            NONFUNGIBLE_POSITION_MANAGER
        ).mint(
                /// @dev The values for tickLower and tickUpper may not work for all tick spacings. Setting amount0Min and amount1Min to 0 is unsafe.
                INonfungiblePositionManagerRamses.MintParams({
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
                })
            );

        IERC20(data_.token0).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), 0);
        IERC20(data_.token1).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), 0);

        FuseStorageLib.RamsesV2TokenIds storage tokensIds = FuseStorageLib.getRamsesV2TokenIds();
        tokensIds.indexes[tokenId] = tokensIds.tokenIds.length;
        tokensIds.tokenIds.push(tokenId);

        emit RamsesV2NewPositionFuseEnter(
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

    /**
     * @notice Function to close liquidity positions
     * @param closePositions The data containing the token IDs of the positions to close
     */
    function exit(RamsesV2NewPositionFuseExitData calldata closePositions) public {
        FuseStorageLib.RamsesV2TokenIds storage tokensIds = FuseStorageLib.getRamsesV2TokenIds();

        uint256 len = tokensIds.tokenIds.length;
        uint256 tokenIndex;

        for (uint256 i; i < len; i++) {
            INonfungiblePositionManagerRamses(NONFUNGIBLE_POSITION_MANAGER).burn(closePositions.tokenIds[i]);

            tokenIndex = tokensIds.indexes[closePositions.tokenIds[i]];
            if (tokenIndex != len - 1) {
                tokensIds.tokenIds[tokenIndex] = tokensIds.tokenIds[len - 1];
            }
            tokensIds.tokenIds.pop();

            emit RamsesV2NewPositionFuseExit(VERSION, closePositions.tokenIds[i]);
        }
    }
}

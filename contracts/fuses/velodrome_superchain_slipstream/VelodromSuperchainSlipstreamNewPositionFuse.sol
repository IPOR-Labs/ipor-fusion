// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {INonfungiblePositionManager} from "./ext/INonfungiblePositionManager.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {VelodromSuperchainSlipstreamSubstrateLib, VelodromSuperchainSlipstreamSubstrateType, VelodromSuperchainSlipstreamSubstrate} from "./VelodromSuperchainSlipstreamLib.sol";

struct VelodromSuperchainSlipstreamNewPositionFuseEnterData {
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

struct VelodromSuperchainSlipstreamNewPositionFuseExitData {
    uint256[] tokenIds;
}

contract VelodromSuperchainSlipstreamNewPositionFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    error VelodromSuperchainSlipstreamNewPositionFuseUnsupportedPool(address pool);

    event VelodromSuperchainSlipstreamNewPositionFuseEnter(
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

    event VelodromSuperchainSlipstreamNewPositionFuseExit(address indexed version, uint256 indexed tokenId);

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

    function enter(VelodromSuperchainSlipstreamNewPositionFuseEnterData calldata data_) public {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                VelodromSuperchainSlipstreamSubstrateLib.substrateToBytes32(
                    VelodromSuperchainSlipstreamSubstrate({
                        substrateType: VelodromSuperchainSlipstreamSubstrateType.Pool,
                        substrateAddress: VelodromSuperchainSlipstreamSubstrateLib.getPoolAddress(
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
            revert VelodromSuperchainSlipstreamNewPositionFuseUnsupportedPool(
                VelodromSuperchainSlipstreamSubstrateLib.getPoolAddress(
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

        FuseStorageLib.VelodromSuperchainSlipstreamTokenIds storage tokensIds = FuseStorageLib
            .getVelodromSuperchainSlipstreamTokenIds();
        tokensIds.indexes[tokenId] = tokensIds.tokenIds.length;
        tokensIds.tokenIds.push(tokenId);

        emit VelodromSuperchainSlipstreamNewPositionFuseEnter(
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

    function exit(VelodromSuperchainSlipstreamNewPositionFuseExitData calldata closePositions) public {
        FuseStorageLib.VelodromSuperchainSlipstreamTokenIds storage tokensIds = FuseStorageLib
            .getVelodromSuperchainSlipstreamTokenIds();

        uint256 len = tokensIds.tokenIds.length;
        uint256 tokenIndex;

        for (uint256 i; i < len; i++) {
            INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER).burn(closePositions.tokenIds[i]);

            tokenIndex = tokensIds.indexes[closePositions.tokenIds[i]];
            if (tokenIndex != len - 1) {
                tokensIds.tokenIds[tokenIndex] = tokensIds.tokenIds[len - 1];
            }
            tokensIds.tokenIds.pop();

            emit VelodromSuperchainSlipstreamNewPositionFuseExit(VERSION, closePositions.tokenIds[i]);
        }
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {INonfungiblePositionManager} from "./ext/INonfungiblePositionManager.sol";
import {AreodromeSlipstreamSubstrateLib, AreodromeSlipstreamSubstrateType, AreodromeSlipstreamSubstrate} from "./AreodromeSlipstreamLib.sol";

struct AreodromeSlipstreamModifyPositionFuseEnterData {
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

struct AreodromeSlipstreamModifyPositionFuseExitData {
    /// @notice The ID of the token for which liquidity is being decreased
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

contract AreodromeSlipstreamModifyPositionFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    event AreodromeSlipstreamModifyPositionFuseEnter(
        address version,
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );
    event AreodromeSlipstreamModifyPositionFuseExit(address version, uint256 tokenId, uint256 amount0, uint256 amount1);

    error AreodromeSlipstreamModifyPositionFuseUnsupportedPool(address pool);
    error InvalidAddress();

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    /// @dev Manage NFTs representing liquidity positions
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
    }

    function enter(AreodromeSlipstreamModifyPositionFuseEnterData calldata data_) public {
        (, , address token0, address token1, int24 tickSpacing, , , , , , , ) = INonfungiblePositionManager(
            NONFUNGIBLE_POSITION_MANAGER
        ).positions(data_.tokenId);

        address pool = AreodromeSlipstreamSubstrateLib.getPoolAddress(FACTORY, token0, token1, tickSpacing);

        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                AreodromeSlipstreamSubstrateLib.substrateToBytes32(
                    AreodromeSlipstreamSubstrate({
                        substrateType: AreodromeSlipstreamSubstrateType.Pool,
                        substrateAddress: pool
                    })
                )
            )
        ) {
            revert AreodromeSlipstreamModifyPositionFuseUnsupportedPool(pool);
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

        (uint128 liquidity, uint256 amount0, uint256 amount1) = INonfungiblePositionManager(
            NONFUNGIBLE_POSITION_MANAGER
        ).increaseLiquidity(params);

        IERC20(data_.token0).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), 0);
        IERC20(data_.token1).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), 0);

        emit AreodromeSlipstreamModifyPositionFuseEnter(VERSION, data_.tokenId, liquidity, amount0, amount1);
    }

    function exit(AreodromeSlipstreamModifyPositionFuseExitData calldata data_) public {
        (, , address token0, address token1, int24 tickSpacing, , , , , , , ) = INonfungiblePositionManager(
            NONFUNGIBLE_POSITION_MANAGER
        ).positions(data_.tokenId);

        address pool = AreodromeSlipstreamSubstrateLib.getPoolAddress(FACTORY, token0, token1, tickSpacing);

        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                AreodromeSlipstreamSubstrateLib.substrateToBytes32(
                    AreodromeSlipstreamSubstrate({
                        substrateType: AreodromeSlipstreamSubstrateType.Pool,
                        substrateAddress: pool
                    })
                )
            )
        ) {
            revert AreodromeSlipstreamModifyPositionFuseUnsupportedPool(pool);
        }

        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager
            .DecreaseLiquidityParams({
                tokenId: data_.tokenId,
                liquidity: data_.liquidity,
                amount0Min: data_.amount0Min,
                amount1Min: data_.amount1Min,
                deadline: data_.deadline
            });

        (uint256 amount0, uint256 amount1) = INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER)
            .decreaseLiquidity(params);

        emit AreodromeSlipstreamModifyPositionFuseExit(VERSION, data_.tokenId, amount0, amount1);
    }
}

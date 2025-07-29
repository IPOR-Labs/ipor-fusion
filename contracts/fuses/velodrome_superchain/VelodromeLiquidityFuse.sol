// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRouter} from "./ext/IRouter.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {VelodromeSubstrateLib, VelodromeSubstrate, VelodromeSubstrateType} from "./VelodrimeLib.sol";

struct VelodromeLiquidityFuseEnterData {
    address tokenA;
    address tokenB;
    bool stable;
    uint256 amountADesired;
    uint256 amountBDesired;
    uint256 amountAMin;
    uint256 amountBMin;
    uint256 deadline;
}

struct VelodromeLiquidityFuseExitData {
    address tokenA;
    address tokenB;
    bool stable;
    uint256 liquidity;
    uint256 amountAMin;
    uint256 amountBMin;
    uint256 deadline;
}

contract VelodromeLiquidityFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable VELODROME_ROUTER;

    error VelodromeLiquidityFuseUnsupportedPool(string action, address poolAddress);
    error VelodromeLiquidityFuseAddLiquidityFailed();
    error VelodromeLiquidityFuseInvalidToken();
    event VelodromeLiquidityFuseEnter(
        address version,
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
    );
    event VelodromeLiquidityFuseExit(
        address version,
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
    );

    constructor(uint256 marketId_, address velodromeRouter_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        VELODROME_ROUTER = velodromeRouter_;
    }

    function enter(VelodromeLiquidityFuseEnterData memory data) external {
        if (data.tokenA == address(0) || data.tokenB == address(0)) {
            revert VelodromeLiquidityFuseInvalidToken();
        }

        if (data.amountADesired == 0 && data.amountBDesired == 0) {
            return;
        }

        address poolAddress = IRouter(VELODROME_ROUTER).poolFor(data.tokenA, data.tokenB, data.stable);
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                VelodromeSubstrateLib.substrateToBytes32(
                    VelodromeSubstrate({substrateAddress: poolAddress, substrateType: VelodromeSubstrateType.Pool})
                )
            )
        ) {
            revert VelodromeLiquidityFuseUnsupportedPool("enter", poolAddress);
        }

        if (data.amountADesired > 0) {
            IERC20(data.tokenA).forceApprove(VELODROME_ROUTER, data.amountADesired);
        }

        if (data.amountBDesired > 0) {
            IERC20(data.tokenB).forceApprove(VELODROME_ROUTER, data.amountBDesired);
        }

        (uint256 amountA, uint256 amountB, uint256 liquidity) = IRouter(VELODROME_ROUTER).addLiquidity(
            data.tokenA,
            data.tokenB,
            data.stable,
            data.amountADesired,
            data.amountBDesired,
            data.amountAMin,
            data.amountBMin,
            address(this),
            data.deadline
        );

        if (liquidity == 0) {
            revert VelodromeLiquidityFuseAddLiquidityFailed();
        }

        emit VelodromeLiquidityFuseEnter(VERSION, data.tokenA, data.tokenB, data.stable, amountA, amountB, liquidity);

        IERC20(data.tokenA).forceApprove(poolAddress, 0);
        IERC20(data.tokenB).forceApprove(poolAddress, 0);
    }

    function exit(VelodromeLiquidityFuseExitData memory data) external {
        if (data.tokenA == address(0) || data.tokenB == address(0)) {
            revert VelodromeLiquidityFuseInvalidToken();
        }

        address poolAddress = IRouter(VELODROME_ROUTER).poolFor(data.tokenA, data.tokenB, data.stable);
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                VelodromeSubstrateLib.substrateToBytes32(
                    VelodromeSubstrate({substrateAddress: poolAddress, substrateType: VelodromeSubstrateType.Pool})
                )
            )
        ) {
            revert VelodromeLiquidityFuseUnsupportedPool("exit", poolAddress);
        }

        IERC20(poolAddress).forceApprove(VELODROME_ROUTER, data.liquidity);

        (uint256 amountA, uint256 amountB) = IRouter(VELODROME_ROUTER).removeLiquidity(
            data.tokenA,
            data.tokenB,
            data.stable,
            data.liquidity,
            data.amountAMin,
            data.amountBMin,
            address(this),
            data.deadline
        );

        IERC20(poolAddress).forceApprove(VELODROME_ROUTER, 0);

        emit VelodromeLiquidityFuseExit(
            VERSION,
            data.tokenA,
            data.tokenB,
            data.stable,
            amountA,
            amountB,
            data.liquidity
        );
    }
}

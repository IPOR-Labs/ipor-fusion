// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {VelodromeSuperchainSubstrateLib, VelodromeSuperchainSubstrate, VelodromeSuperchainSubstrateType} from "./VelodromeSuperchainLib.sol";
import {IRouter} from "./ext/IRouter.sol";

struct VelodromeSuperchainLiquidityFuseEnterData {
    address tokenA;
    address tokenB;
    bool stable;
    uint256 amountADesired;
    uint256 amountBDesired;
    uint256 amountAMin;
    uint256 amountBMin;
    uint256 deadline;
}

struct VelodromeSuperchainLiquidityFuseExitData {
    address tokenA;
    address tokenB;
    bool stable;
    uint256 liquidity;
    uint256 amountAMin;
    uint256 amountBMin;
    uint256 deadline;
}

contract VelodromeSuperchainLiquidityFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable VELODROME_ROUTER;

    error VelodromeSuperchainLiquidityFuseUnsupportedPool(string action, address poolAddress);
    error VelodromeSuperchainLiquidityFuseAddLiquidityFailed();
    error VelodromeSuperchainLiquidityFuseInvalidToken();
    event VelodromeSuperchainLiquidityFuseEnter(
        address version,
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
    );
    event VelodromeSuperchainLiquidityFuseExit(
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

    function enter(VelodromeSuperchainLiquidityFuseEnterData memory data_) external {
        if (data_.tokenA == address(0) || data_.tokenB == address(0)) {
            revert VelodromeSuperchainLiquidityFuseInvalidToken();
        }

        if (data_.amountADesired == 0 && data_.amountBDesired == 0) {
            return;
        }

        address poolAddress = IRouter(VELODROME_ROUTER).poolFor(data_.tokenA, data_.tokenB, data_.stable);
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                VelodromeSuperchainSubstrateLib.substrateToBytes32(
                    VelodromeSuperchainSubstrate({
                        substrateAddress: poolAddress,
                        substrateType: VelodromeSuperchainSubstrateType.Pool
                    })
                )
            )
        ) {
            revert VelodromeSuperchainLiquidityFuseUnsupportedPool("enter", poolAddress);
        }

        if (data_.amountADesired > 0) {
            IERC20(data_.tokenA).forceApprove(VELODROME_ROUTER, data_.amountADesired);
        }

        if (data_.amountBDesired > 0) {
            IERC20(data_.tokenB).forceApprove(VELODROME_ROUTER, data_.amountBDesired);
        }

        (uint256 amountA, uint256 amountB, uint256 liquidity) = IRouter(VELODROME_ROUTER).addLiquidity(
            data_.tokenA,
            data_.tokenB,
            data_.stable,
            data_.amountADesired,
            data_.amountBDesired,
            data_.amountAMin,
            data_.amountBMin,
            address(this),
            data_.deadline
        );

        if (liquidity == 0) {
            revert VelodromeSuperchainLiquidityFuseAddLiquidityFailed();
        }

        emit VelodromeSuperchainLiquidityFuseEnter(
            VERSION,
            data_.tokenA,
            data_.tokenB,
            data_.stable,
            amountA,
            amountB,
            liquidity
        );

        IERC20(data_.tokenA).forceApprove(poolAddress, 0);
        IERC20(data_.tokenB).forceApprove(poolAddress, 0);
    }

    function exit(VelodromeSuperchainLiquidityFuseExitData memory data_) external {
        if (data_.tokenA == address(0) || data_.tokenB == address(0)) {
            revert VelodromeSuperchainLiquidityFuseInvalidToken();
        }

        address poolAddress = IRouter(VELODROME_ROUTER).poolFor(data_.tokenA, data_.tokenB, data_.stable);
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                VelodromeSuperchainSubstrateLib.substrateToBytes32(
                    VelodromeSuperchainSubstrate({
                        substrateAddress: poolAddress,
                        substrateType: VelodromeSuperchainSubstrateType.Pool
                    })
                )
            )
        ) {
            revert VelodromeSuperchainLiquidityFuseUnsupportedPool("exit", poolAddress);
        }

        IERC20(poolAddress).forceApprove(VELODROME_ROUTER, data_.liquidity);

        (uint256 amountA, uint256 amountB) = IRouter(VELODROME_ROUTER).removeLiquidity(
            data_.tokenA,
            data_.tokenB,
            data_.stable,
            data_.liquidity,
            data_.amountAMin,
            data_.amountBMin,
            address(this),
            data_.deadline
        );

        IERC20(poolAddress).forceApprove(VELODROME_ROUTER, 0);

        emit VelodromeSuperchainLiquidityFuseExit(
            VERSION,
            data_.tokenA,
            data_.tokenB,
            data_.stable,
            amountA,
            amountB,
            data_.liquidity
        );
    }
}

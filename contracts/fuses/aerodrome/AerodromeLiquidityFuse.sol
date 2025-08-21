// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRouter} from "./ext/IRouter.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {AerodromeSubstrateLib, AerodromeSubstrate, AerodromeSubstrateType} from "./AreodromeLib.sol";

struct AerodromeLiquidityFuseEnterData {
    address tokenA;
    address tokenB;
    bool stable;
    uint256 amountADesired;
    uint256 amountBDesired;
    uint256 amountAMin;
    uint256 amountBMin;
    uint256 deadline;
}

struct AerodromeLiquidityFuseExitData {
    address tokenA;
    address tokenB;
    bool stable;
    uint256 liquidity;
    uint256 amountAMin;
    uint256 amountBMin;
    uint256 deadline;
}

contract AerodromeLiquidityFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable AREODROME_ROUTER;

    error AerodromeLiquidityFuseUnsupportedPool(string action, address poolAddress);
    error AerodromeLiquidityFuseAddLiquidityFailed();
    error AerodromeLiquidityFuseInvalidToken();
    event AerodromeLiquidityFuseEnter(
        address version,
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
    );
    event AerodromeLiquidityFuseExit(
        address version,
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
    );

    constructor(uint256 marketId_, address areodromeRouter_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        AREODROME_ROUTER = areodromeRouter_;
    }

    function enter(AerodromeLiquidityFuseEnterData memory data_) external {
        if (data_.tokenA == address(0) || data_.tokenB == address(0)) {
            revert AerodromeLiquidityFuseInvalidToken();
        }

        if (data_.amountADesired == 0 && data_.amountBDesired == 0) {
            return;
        }

        address poolAddress = IRouter(AREODROME_ROUTER).poolFor(data_.tokenA, data_.tokenB, data_.stable, address(0));
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                AerodromeSubstrateLib.substrateToBytes32(
                    AerodromeSubstrate({substrateAddress: poolAddress, substrateType: AerodromeSubstrateType.Pool})
                )
            )
        ) {
            revert AerodromeLiquidityFuseUnsupportedPool("enter", poolAddress);
        }

        if (data_.amountADesired > 0) {
            IERC20(data_.tokenA).forceApprove(AREODROME_ROUTER, data_.amountADesired);
        }

        if (data_.amountBDesired > 0) {
            IERC20(data_.tokenB).forceApprove(AREODROME_ROUTER, data_.amountBDesired);
        }

        (uint256 amountA, uint256 amountB, uint256 liquidity) = IRouter(AREODROME_ROUTER).addLiquidity(
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
            revert AerodromeLiquidityFuseAddLiquidityFailed();
        }

        emit AerodromeLiquidityFuseEnter(
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

    function exit(AerodromeLiquidityFuseExitData memory data_) external {
        if (data_.tokenA == address(0) || data_.tokenB == address(0)) {
            revert AerodromeLiquidityFuseInvalidToken();
        }

        address poolAddress = IRouter(AREODROME_ROUTER).poolFor(data_.tokenA, data_.tokenB, data_.stable, address(0));
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                AerodromeSubstrateLib.substrateToBytes32(
                    AerodromeSubstrate({substrateAddress: poolAddress, substrateType: AerodromeSubstrateType.Pool})
                )
            )
        ) {
            revert AerodromeLiquidityFuseUnsupportedPool("exit", poolAddress);
        }

        IERC20(poolAddress).forceApprove(AREODROME_ROUTER, data_.liquidity);

        (uint256 amountA, uint256 amountB) = IRouter(AREODROME_ROUTER).removeLiquidity(
            data_.tokenA,
            data_.tokenB,
            data_.stable,
            data_.liquidity,
            data_.amountAMin,
            data_.amountBMin,
            address(this),
            data_.deadline
        );

        IERC20(poolAddress).forceApprove(AREODROME_ROUTER, 0);

        emit AerodromeLiquidityFuseExit(
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

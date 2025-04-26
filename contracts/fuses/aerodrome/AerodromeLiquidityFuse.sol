// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRouter} from "./ext/IRouter.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

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

    constructor(uint256 marketIdInput, address areodromeRouterInput) {
        VERSION = address(this);
        MARKET_ID = marketIdInput;
        AREODROME_ROUTER = areodromeRouterInput;
    }

    function enter(AerodromeLiquidityFuseEnterData memory data) external {
        if (data.tokenA == address(0) || data.tokenB == address(0)) {
            revert AerodromeLiquidityFuseInvalidToken();
        }

        address poolAddress = IRouter(AREODROME_ROUTER).poolFor(data.tokenA, data.tokenB, data.stable, address(0));
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, poolAddress)) {
            revert AerodromeLiquidityFuseUnsupportedPool("enter", poolAddress);
        }

        if (data.amountADesired == 0 && data.amountBDesired == 0) {
            return;
        }

        if (data.amountADesired > 0) {
            IERC20(data.tokenA).forceApprove(poolAddress, data.amountADesired);
        }

        if (data.amountBDesired > 0) {
            IERC20(data.tokenB).forceApprove(poolAddress, data.amountBDesired);
        }

        (uint256 amountA, uint256 amountB, uint256 liquidity) = IRouter(AREODROME_ROUTER).addLiquidity(
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
            revert AerodromeLiquidityFuseAddLiquidityFailed();
        }

        emit AerodromeLiquidityFuseEnter(VERSION, data.tokenA, data.tokenB, data.stable, amountA, amountB, liquidity);

        IERC20(data.tokenA).forceApprove(poolAddress, 0);
        IERC20(data.tokenB).forceApprove(poolAddress, 0);
    }

    function exit(AerodromeLiquidityFuseExitData memory data) external {
        if (data.tokenA == address(0) || data.tokenB == address(0)) {
            revert AerodromeLiquidityFuseInvalidToken();
        }

        address poolAddress = IRouter(AREODROME_ROUTER).poolFor(data.tokenA, data.tokenB, data.stable, address(0));
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, poolAddress)) {
            revert AerodromeLiquidityFuseUnsupportedPool("exit", poolAddress);
        }

        IERC20(poolAddress).forceApprove(AREODROME_ROUTER, data.liquidity);

        (uint256 amountA, uint256 amountB) = IRouter(AREODROME_ROUTER).removeLiquidity(
            data.tokenA,
            data.tokenB,
            data.stable,
            data.liquidity,
            data.amountAMin,
            data.amountBMin,
            address(this),
            data.deadline
        );

        IERC20(poolAddress).forceApprove(AREODROME_ROUTER, 0);

        emit AerodromeLiquidityFuseExit(
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

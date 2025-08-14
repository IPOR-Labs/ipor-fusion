// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

import {IRouter} from "./ext/IRouter.sol";
import {BalancerSubstrateLib, BalancerSubstrateType, BalancerSubstrate} from "./BalancerSubstrateLib.sol";

struct BalancerSingleTokenFuseEnterData {
    address pool;
    address tokenIn;
    uint256 maxAmountIn;
    uint256 exactBptAmountOut;
}

contract BalancerSingleTokenFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable BALANCER_ROUTER;

    error BalancerSingleTokenFuseUnsupportedPool(address pool);
    error BalancerSingleTokenFuseInvalidParams();
    error InvalidAddress();

    event BalancerSingleTokenFuseEnter(
        address indexed version,
        address indexed pool,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 exactBptAmountOut
    );

    event BalancerSingleTokenFuseExit(
        address indexed version,
        address indexed pool,
        address indexed tokenOut,
        uint256 bptAmountIn,
        uint256 exactAmountOut
    );

    constructor(uint256 marketId_, address balancerRouter_) {
        if (balancerRouter_ == address(0)) {
            revert InvalidAddress();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        BALANCER_ROUTER = balancerRouter_;
    }

    function enter(BalancerSingleTokenFuseEnterData calldata data_) external {
        if (data_.pool == address(0) || data_.tokenIn == address(0)) {
            revert BalancerSingleTokenFuseInvalidParams();
        }

        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                BalancerSubstrateLib.substrateToBytes32(
                    BalancerSubstrate({substrateType: BalancerSubstrateType.POOL, substrateAddress: data_.pool})
                )
            )
        ) {
            revert BalancerSingleTokenFuseUnsupportedPool(data_.pool);
        }

        if (data_.maxAmountIn == 0) {
            return;
        }

        IERC20(data_.tokenIn).forceApprove(BALANCER_ROUTER, data_.maxAmountIn);

        uint256 amountIn = IRouter(BALANCER_ROUTER).addLiquiditySingleTokenExactOut(
            data_.pool,
            IERC20(data_.tokenIn),
            data_.maxAmountIn,
            data_.exactBptAmountOut,
            false,
            ""
        );

        emit BalancerSingleTokenFuseEnter(VERSION, data_.pool, data_.tokenIn, amountIn, data_.exactBptAmountOut);

        IERC20(data_.tokenIn).forceApprove(BALANCER_ROUTER, 0);
    }

    struct BalancerSingleTokenFuseExitData {
        address pool;
        address tokenOut;
        uint256 maxBptAmountIn;
        uint256 exactAmountOut;
    }

    function exit(BalancerSingleTokenFuseExitData calldata data_) external payable {
        if (data_.pool == address(0) || data_.tokenOut == address(0)) {
            revert BalancerSingleTokenFuseInvalidParams();
        }

        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                BalancerSubstrateLib.substrateToBytes32(
                    BalancerSubstrate({substrateType: BalancerSubstrateType.POOL, substrateAddress: data_.pool})
                )
            )
        ) {
            revert BalancerSingleTokenFuseUnsupportedPool(data_.pool);
        }

        if (data_.maxBptAmountIn == 0) {
            return;
        }

        IERC20(data_.pool).forceApprove(BALANCER_ROUTER, data_.maxBptAmountIn);

        uint256 bptAmountIn = IRouter(BALANCER_ROUTER).removeLiquiditySingleTokenExactOut{value: msg.value}(
            data_.pool,
            data_.maxBptAmountIn,
            IERC20(data_.tokenOut),
            data_.exactAmountOut,
            false,
            ""
        );

        emit BalancerSingleTokenFuseExit(VERSION, data_.pool, data_.tokenOut, bptAmountIn, data_.exactAmountOut);

        IERC20(data_.pool).forceApprove(BALANCER_ROUTER, 0);
    }
}

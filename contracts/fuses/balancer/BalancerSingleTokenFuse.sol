// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

import {IRouter} from "./ext/IRouter.sol";
import {BalancerSubstrateLib, BalancerSubstrateType, BalancerSubstrate} from "./BalancerSubstrateLib.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPermit2} from "./ext/IPermit2.sol";

struct BalancerSingleTokenFuseEnterData {
    address pool;
    address tokenIn;
    uint256 maxAmountIn;
    uint256 exactBptAmountOut;
}

struct BalancerSingleTokenFuseExitData {
    address pool;
    address tokenOut;
    uint256 maxBptAmountIn;
    uint256 exactAmountOut;
}

contract BalancerSingleTokenFuse is IFuseCommon {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable BALANCER_ROUTER;
    address public immutable PERMIT2;

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

    constructor(uint256 marketId_, address balancerRouter_, address permit2_) {
        if (balancerRouter_ == address(0)) {
            revert InvalidAddress();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        BALANCER_ROUTER = balancerRouter_;
        PERMIT2 = permit2_;
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

        address[] memory tokens = new address[](1);
        tokens[0] = data_.tokenIn;

        BalancerSubstrateLib.checkTokensInPool(data_.pool, tokens);

        IERC20(data_.tokenIn).forceApprove(PERMIT2, data_.maxAmountIn);
        IPermit2(PERMIT2).approve(
            data_.tokenIn,
            BALANCER_ROUTER,
            data_.maxAmountIn.toUint160(),
            uint48(block.timestamp + 1)
        );

        uint256 amountIn = IRouter(BALANCER_ROUTER).addLiquiditySingleTokenExactOut(
            data_.pool,
            IERC20(data_.tokenIn),
            data_.maxAmountIn,
            data_.exactBptAmountOut,
            false,
            ""
        );

        emit BalancerSingleTokenFuseEnter(VERSION, data_.pool, data_.tokenIn, amountIn, data_.exactBptAmountOut);

        IERC20(data_.tokenIn).forceApprove(PERMIT2, 0);
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

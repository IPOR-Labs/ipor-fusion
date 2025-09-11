// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

import {IRouter} from "./ext/IRouter.sol";
import {BalancerSubstrateLib, BalancerSubstrateType, BalancerSubstrate} from "./BalancerSubstrateLib.sol";
import {IPermit2} from "./ext/IPermit2.sol";

struct BalancerLiquidityUnbalancedFuseEnterData {
    address pool;
    address[] tokens;
    uint256[] exactAmountsIn;
    uint256 minBptAmountOut;
}

struct BalancerLiquidityUnbalancedFuseExitData {
    address pool;
    uint256 maxBptAmountIn;
    uint256[] minAmountsOut;
}

contract BalancerLiquidityUnbalancedFuse is IFuseCommon {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable BALANCER_ROUTER;
    address public immutable PERMIT2;

    error BalancerLiquidityUnbalancedFuseUnsupportedPool(address pool);
    error BalancerLiquidityUnbalancedFuseInvalidParams();
    error InvalidAddress();

    event BalancerLiquidityUnbalancedFuseEnter(
        address indexed version,
        address indexed pool,
        uint256 bptAmountOut,
        uint256[] amountsIn
    );

    event BalancerLiquidityUnbalancedFuseExit(
        address indexed version,
        address indexed pool,
        uint256 bptAmountIn,
        uint256[] amountsOut
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

    function enter(BalancerLiquidityUnbalancedFuseEnterData calldata data_) external payable {
        if (data_.pool == address(0)) {
            revert BalancerLiquidityUnbalancedFuseInvalidParams();
        }
        if (data_.tokens.length != data_.exactAmountsIn.length) {
            revert BalancerLiquidityUnbalancedFuseInvalidParams();
        }

        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                BalancerSubstrateLib.substrateToBytes32(
                    BalancerSubstrate({substrateType: BalancerSubstrateType.POOL, substrateAddress: data_.pool})
                )
            )
        ) {
            revert BalancerLiquidityUnbalancedFuseUnsupportedPool(data_.pool);
        }

        uint256 len = data_.tokens.length;
        for (uint256 i; i < len; ++i) {
            uint256 amountIn = data_.exactAmountsIn[i];
            if (amountIn > 0) {
                IERC20(data_.tokens[i]).forceApprove(PERMIT2, type(uint256).max);
                IPermit2(PERMIT2).approve(
                    data_.tokens[i],
                    BALANCER_ROUTER,
                    amountIn.toUint160(),
                    uint48(block.timestamp + 1)
                );
            }
        }

        uint256 bptAmountOut = IRouter(BALANCER_ROUTER).addLiquidityUnbalanced(
            data_.pool,
            data_.exactAmountsIn,
            data_.minBptAmountOut,
            false,
            ""
        );

        emit BalancerLiquidityUnbalancedFuseEnter(VERSION, data_.pool, bptAmountOut, data_.exactAmountsIn);

        for (uint256 i; i < len; ++i) {
            if (data_.exactAmountsIn[i] > 0) {
                IERC20(data_.tokens[i]).forceApprove(BALANCER_ROUTER, 0);
            }
        }
    }

    function exit(BalancerLiquidityUnbalancedFuseExitData calldata data_) external payable {
        if (data_.pool == address(0)) {
            revert BalancerLiquidityUnbalancedFuseInvalidParams();
        }

        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                BalancerSubstrateLib.substrateToBytes32(
                    BalancerSubstrate({substrateType: BalancerSubstrateType.POOL, substrateAddress: data_.pool})
                )
            )
        ) {
            revert BalancerLiquidityUnbalancedFuseUnsupportedPool(data_.pool);
        }

        if (data_.maxBptAmountIn == 0) {
            return;
        }

        IERC20(data_.pool).forceApprove(BALANCER_ROUTER, data_.maxBptAmountIn);

        (uint256 bptAmountIn, uint256[] memory amountsOut, ) = IRouter(BALANCER_ROUTER).removeLiquidityCustom(
            data_.pool,
            data_.maxBptAmountIn,
            data_.minAmountsOut,
            false,
            ""
        );

        emit BalancerLiquidityUnbalancedFuseExit(VERSION, data_.pool, bptAmountIn, amountsOut);

        IERC20(data_.pool).forceApprove(BALANCER_ROUTER, 0);
    }
}

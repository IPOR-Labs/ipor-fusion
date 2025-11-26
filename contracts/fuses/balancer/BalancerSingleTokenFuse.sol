// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";

import {IRouter} from "./ext/IRouter.sol";
import {BalancerSubstrateLib, BalancerSubstrateType, BalancerSubstrate} from "./BalancerSubstrateLib.sol";
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

    function enter(BalancerSingleTokenFuseEnterData memory data_) public payable returns (uint256 amountIn) {
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
            return 0;
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

        amountIn = IRouter(BALANCER_ROUTER).addLiquiditySingleTokenExactOut(
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

    /// @notice Adds single token liquidity using transient storage for input parameters
    /// @dev Reads inputs from transient storage, calls enter(), and writes outputs to transient storage
    function enterTransient() external payable {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        BalancerSingleTokenFuseEnterData memory data = BalancerSingleTokenFuseEnterData({
            pool: TypeConversionLib.toAddress(inputs[0]),
            tokenIn: TypeConversionLib.toAddress(inputs[1]),
            maxAmountIn: TypeConversionLib.toUint256(inputs[2]),
            exactBptAmountOut: TypeConversionLib.toUint256(inputs[3])
        });

        uint256 amountIn = enter(data);

        bytes32[] memory outputs = new bytes32[](1);
        outputs[0] = TypeConversionLib.toBytes32(amountIn);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    function exit(BalancerSingleTokenFuseExitData memory data_) public payable returns (uint256 bptAmountIn) {
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
            return 0;
        }

        IERC20(data_.pool).forceApprove(BALANCER_ROUTER, data_.maxBptAmountIn);

        bptAmountIn = IRouter(BALANCER_ROUTER).removeLiquiditySingleTokenExactOut{value: msg.value}(
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

    /// @notice Removes single token liquidity using transient storage for input parameters
    /// @dev Reads inputs from transient storage, calls exit(), and writes outputs to transient storage
    function exitTransient() external payable {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        BalancerSingleTokenFuseExitData memory data = BalancerSingleTokenFuseExitData({
            pool: TypeConversionLib.toAddress(inputs[0]),
            tokenOut: TypeConversionLib.toAddress(inputs[1]),
            maxBptAmountIn: TypeConversionLib.toUint256(inputs[2]),
            exactAmountOut: TypeConversionLib.toUint256(inputs[3])
        });

        uint256 bptAmountIn = exit(data);

        bytes32[] memory outputs = new bytes32[](1);
        outputs[0] = TypeConversionLib.toBytes32(bptAmountIn);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}

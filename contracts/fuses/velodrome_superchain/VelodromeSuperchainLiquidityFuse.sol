// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
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

struct VelodromeSuperchainLiquidityFuseResult {
    address tokenA;
    address tokenB;
    bool stable;
    uint256 amountA;
    uint256 amountB;
    uint256 liquidity;
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

    function enter(
        VelodromeSuperchainLiquidityFuseEnterData memory data_
    ) public returns (VelodromeSuperchainLiquidityFuseResult memory result) {
        if (data_.tokenA == address(0) || data_.tokenB == address(0)) {
            revert VelodromeSuperchainLiquidityFuseInvalidToken();
        }

        result.tokenA = data_.tokenA;
        result.tokenB = data_.tokenB;
        result.stable = data_.stable;

        if (data_.amountADesired == 0 && data_.amountBDesired == 0) {
            result.amountA = 0;
            result.amountB = 0;
            result.liquidity = 0;
            return result;
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

        (result.amountA, result.amountB, result.liquidity) = IRouter(VELODROME_ROUTER).addLiquidity(
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

        if (result.liquidity == 0) {
            revert VelodromeSuperchainLiquidityFuseAddLiquidityFailed();
        }

        emit VelodromeSuperchainLiquidityFuseEnter(
            VERSION,
            result.tokenA,
            result.tokenB,
            result.stable,
            result.amountA,
            result.amountB,
            result.liquidity
        );

        IERC20(data_.tokenA).forceApprove(poolAddress, 0);
        IERC20(data_.tokenB).forceApprove(poolAddress, 0);
    }

    function exit(
        VelodromeSuperchainLiquidityFuseExitData memory data_
    ) public returns (VelodromeSuperchainLiquidityFuseResult memory result) {
        if (data_.tokenA == address(0) || data_.tokenB == address(0)) {
            revert VelodromeSuperchainLiquidityFuseInvalidToken();
        }

        result.tokenA = data_.tokenA;
        result.tokenB = data_.tokenB;
        result.stable = data_.stable;
        result.liquidity = data_.liquidity;

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

        (result.amountA, result.amountB) = IRouter(VELODROME_ROUTER).removeLiquidity(
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
            result.tokenA,
            result.tokenB,
            result.stable,
            result.amountA,
            result.amountB,
            result.liquidity
        );
    }

    /// @notice Enters the Fuse using transient storage for parameters
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        VelodromeSuperchainLiquidityFuseResult memory result = enter(
            VelodromeSuperchainLiquidityFuseEnterData(
                TypeConversionLib.toAddress(inputs[0]),
                TypeConversionLib.toAddress(inputs[1]),
                TypeConversionLib.toUint256(inputs[2]) == 1,
                TypeConversionLib.toUint256(inputs[3]),
                TypeConversionLib.toUint256(inputs[4]),
                TypeConversionLib.toUint256(inputs[5]),
                TypeConversionLib.toUint256(inputs[6]),
                TypeConversionLib.toUint256(inputs[7])
            )
        );

        bytes32[] memory outputs = new bytes32[](6);
        outputs[0] = TypeConversionLib.toBytes32(result.tokenA);
        outputs[1] = TypeConversionLib.toBytes32(result.tokenB);
        outputs[2] = TypeConversionLib.toBytes32(result.stable ? 1 : 0);
        outputs[3] = TypeConversionLib.toBytes32(result.amountA);
        outputs[4] = TypeConversionLib.toBytes32(result.amountB);
        outputs[5] = TypeConversionLib.toBytes32(result.liquidity);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits the Fuse using transient storage for parameters
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        VelodromeSuperchainLiquidityFuseResult memory result = exit(
            VelodromeSuperchainLiquidityFuseExitData(
                TypeConversionLib.toAddress(inputs[0]),
                TypeConversionLib.toAddress(inputs[1]),
                TypeConversionLib.toUint256(inputs[2]) == 1,
                TypeConversionLib.toUint256(inputs[3]),
                TypeConversionLib.toUint256(inputs[4]),
                TypeConversionLib.toUint256(inputs[5]),
                TypeConversionLib.toUint256(inputs[6])
            )
        );

        bytes32[] memory outputs = new bytes32[](6);
        outputs[0] = TypeConversionLib.toBytes32(result.tokenA);
        outputs[1] = TypeConversionLib.toBytes32(result.tokenB);
        outputs[2] = TypeConversionLib.toBytes32(result.stable ? 1 : 0);
        outputs[3] = TypeConversionLib.toBytes32(result.amountA);
        outputs[4] = TypeConversionLib.toBytes32(result.amountB);
        outputs[5] = TypeConversionLib.toBytes32(result.liquidity);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}

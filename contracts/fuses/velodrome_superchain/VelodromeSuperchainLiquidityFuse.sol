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

/// @notice Data structure used for entering a liquidity provision operation
/// @param tokenA The address of the first token in the pair
/// @param tokenB The address of the second token in the pair
/// @param stable Whether the pool is a stable pool (true) or volatile pool (false)
/// @param amountADesired The desired amount of tokenA to add as liquidity
/// @param amountBDesired The desired amount of tokenB to add as liquidity
/// @param amountAMin The minimum amount of tokenA that must be added (slippage protection)
/// @param amountBMin The minimum amount of tokenB that must be added (slippage protection)
/// @param deadline The unix timestamp after which the transaction will revert
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

/// @notice Data structure used for exiting a liquidity removal operation
/// @param tokenA The address of the first token in the pair
/// @param tokenB The address of the second token in the pair
/// @param stable Whether the pool is a stable pool (true) or volatile pool (false)
/// @param liquidity The amount of LP tokens to remove
/// @param amountAMin The minimum amount of tokenA that must be received (slippage protection)
/// @param amountBMin The minimum amount of tokenB that must be received (slippage protection)
/// @param deadline The unix timestamp after which the transaction will revert
struct VelodromeSuperchainLiquidityFuseExitData {
    address tokenA;
    address tokenB;
    bool stable;
    uint256 liquidity;
    uint256 amountAMin;
    uint256 amountBMin;
    uint256 deadline;
}

/// @notice Data structure returned from enter and exit operations
/// @param tokenA The address of the first token in the pair
/// @param tokenB The address of the second token in the pair
/// @param stable Whether the pool is a stable pool (true) or volatile pool (false)
/// @param amountA The actual amount of tokenA added or received
/// @param amountB The actual amount of tokenB added or received
/// @param liquidity The actual amount of LP tokens minted or burned
struct VelodromeSuperchainLiquidityFuseResult {
    address tokenA;
    address tokenB;
    bool stable;
    uint256 amountA;
    uint256 amountB;
    uint256 liquidity;
}

/**
 * @title VelodromeSuperchainLiquidityFuse
 * @notice Fuse contract for adding and removing liquidity to/from Velodrome Superchain pools
 * @dev This contract allows the Plasma Vault to interact with Velodrome Superchain liquidity pools,
 *      enabling the addition and removal of liquidity. It validates pool addresses, checks substrate
 *      permissions, handles approvals using forceApprove pattern, and enforces slippage protection.
 *      Supports both standard and transient storage patterns for gas-efficient operations.
 * @author IPOR Labs
 */
contract VelodromeSuperchainLiquidityFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable VELODROME_ROUTER;

    error VelodromeSuperchainLiquidityFuseUnsupportedPool(string action, address poolAddress);
    error VelodromeSuperchainLiquidityFuseAddLiquidityFailed();
    error VelodromeSuperchainLiquidityFuseInvalidToken();
    error VelodromeSuperchainLiquidityFuseInvalidRouter();
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

    /**
     * @notice Initializes the VelodromeSuperchainLiquidityFuse with market ID and router address
     * @param marketId_ The market ID used to identify the market and validate pool substrates
     * @param velodromeRouter_ The address of the Velodrome Superchain router contract (must not be address(0))
     * @dev Reverts if velodromeRouter_ is zero address
     */
    constructor(uint256 marketId_, address velodromeRouter_) {
        if (velodromeRouter_ == address(0)) {
            revert VelodromeSuperchainLiquidityFuseInvalidRouter();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        VELODROME_ROUTER = velodromeRouter_;
    }

    /**
     * @notice Adds liquidity to a Velodrome Superchain pool
     * @dev Validates token addresses, checks pool substrate permissions, approves tokens using
     *      forceApprove pattern, calls router to add liquidity, and validates the result.
     *      Reverts if tokens are invalid, pool is not granted as substrate, or liquidity is zero.
     * @param data_ The enter data containing pool parameters, amounts, and slippage protection
     * @return result The result containing actual amounts added and liquidity received
     * @custom:reverts VelodromeSuperchainLiquidityFuseInvalidToken If tokenA or tokenB is zero address
     * @custom:reverts VelodromeSuperchainLiquidityFuseUnsupportedPool If pool is not granted as a substrate
     * @custom:reverts VelodromeSuperchainLiquidityFuseAddLiquidityFailed If liquidity result is zero
     */
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

        IERC20(data_.tokenA).forceApprove(VELODROME_ROUTER, 0);
        IERC20(data_.tokenB).forceApprove(VELODROME_ROUTER, 0);
    }

    /**
     * @notice Removes liquidity from a Velodrome Superchain pool
     * @dev Validates token addresses, checks pool substrate permissions, approves LP tokens using
     *      forceApprove pattern, calls router to remove liquidity, and resets approvals.
     *      Reverts if tokens are invalid or pool is not granted as substrate.
     * @param data_ The exit data containing pool parameters, liquidity amount, and slippage protection
     * @return result The result containing actual amounts received and liquidity removed
     * @custom:reverts VelodromeSuperchainLiquidityFuseInvalidToken If tokenA or tokenB is zero address
     * @custom:reverts VelodromeSuperchainLiquidityFuseUnsupportedPool If pool is not granted as a substrate
     */
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

    /**
     * @notice Enters the Fuse using transient storage for parameters
     * @dev Reads tokenA, tokenB, stable, amountADesired, amountBDesired, amountAMin, amountBMin, and deadline
     *      from transient storage inputs, calls enter() with the decoded data, and writes the result
     *      (tokenA, tokenB, stable, amountA, amountB, liquidity) to transient storage outputs.
     *      Input 0: tokenA (address)
     *      Input 1: tokenB (address)
     *      Input 2: stable (uint256, 1 for true, 0 for false)
     *      Input 3: amountADesired (uint256)
     *      Input 4: amountBDesired (uint256)
     *      Input 5: amountAMin (uint256)
     *      Input 6: amountBMin (uint256)
     *      Input 7: deadline (uint256)
     *      Output 0: tokenA (address)
     *      Output 1: tokenB (address)
     *      Output 2: stable (uint256, 1 for true, 0 for false)
     *      Output 3: amountA (uint256)
     *      Output 4: amountB (uint256)
     *      Output 5: liquidity (uint256)
     */
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

    /**
     * @notice Exits the Fuse using transient storage for parameters
     * @dev Reads tokenA, tokenB, stable, liquidity, amountAMin, amountBMin, and deadline
     *      from transient storage inputs, calls exit() with the decoded data, and writes the result
     *      (tokenA, tokenB, stable, amountA, amountB, liquidity) to transient storage outputs.
     *      Input 0: tokenA (address)
     *      Input 1: tokenB (address)
     *      Input 2: stable (uint256, 1 for true, 0 for false)
     *      Input 3: liquidity (uint256)
     *      Input 4: amountAMin (uint256)
     *      Input 5: amountBMin (uint256)
     *      Input 6: deadline (uint256)
     *      Output 0: tokenA (address)
     *      Output 1: tokenB (address)
     *      Output 2: stable (uint256, 1 for true, 0 for false)
     *      Output 3: amountA (uint256)
     *      Output 4: amountB (uint256)
     *      Output 5: liquidity (uint256)
     */
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

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {AerodromeSubstrate, AerodromeSubstrateLib, AerodromeSubstrateType} from "./AreodromeLib.sol";
import {IRouter} from "./ext/IRouter.sol";

/// @notice Structure containing data for adding liquidity to an Aerodrome pool
/// @param tokenA The address of the first token in the pair
/// @param tokenB The address of the second token in the pair
/// @param stable Whether the pool is a stable pool (true) or volatile pool (false)
/// @param amountADesired The desired amount of tokenA to add
/// @param amountBDesired The desired amount of tokenB to add
/// @param amountAMin The minimum amount of tokenA to add (slippage protection)
/// @param amountBMin The minimum amount of tokenB to add (slippage protection)
/// @param deadline The deadline timestamp for the transaction
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

/// @notice Structure containing data for removing liquidity from an Aerodrome pool
/// @param tokenA The address of the first token in the pair
/// @param tokenB The address of the second token in the pair
/// @param stable Whether the pool is a stable pool (true) or volatile pool (false)
/// @param liquidity The amount of LP tokens to remove
/// @param amountAMin The minimum amount of tokenA to receive (slippage protection)
/// @param amountBMin The minimum amount of tokenB to receive (slippage protection)
/// @param deadline The deadline timestamp for the transaction
struct AerodromeLiquidityFuseExitData {
    address tokenA;
    address tokenB;
    bool stable;
    uint256 liquidity;
    uint256 amountAMin;
    uint256 amountBMin;
    uint256 deadline;
}

/// @notice Structure containing the response data for liquidity operations
/// @param tokenA The address of the first token in the pair
/// @param tokenB The address of the second token in the pair
/// @param stable Whether the pool is a stable pool (true) or volatile pool (false)
/// @param amountA The actual amount of tokenA involved
/// @param amountB The actual amount of tokenB involved
/// @param liquidity The amount of LP tokens involved
struct AerodromeLiquidityFuseResponse {
    address tokenA;
    address tokenB;
    bool stable;
    uint256 amountA;
    uint256 amountB;
    uint256 liquidity;
}

/// @title AerodromeLiquidityFuse
/// @notice Fuse for adding and removing liquidity from Aerodrome protocol pools
/// @dev This fuse allows Plasma Vault to interact with Aerodrome pools by adding liquidity
///      (depositing tokens and receiving LP tokens) or removing liquidity (burning LP tokens
///      and receiving underlying tokens). The pool address must be granted as a substrate
///      for the specified MARKET_ID. The fuse handles token approvals and ensures proper
///      slippage protection.
/// @author IPOR Labs
contract AerodromeLiquidityFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    /// @notice The address of this fuse version for tracking purposes
    address public immutable VERSION;

    /// @notice The market ID associated with this fuse
    /// @dev This ID is used to validate that pool addresses are granted as substrates for this market
    uint256 public immutable MARKET_ID;

    /// @notice The address of the Aerodrome router contract
    /// @dev This router is used to interact with Aerodrome pools for adding/removing liquidity
    address public immutable AREODROME_ROUTER;

    /// @notice Thrown when attempting to interact with a pool that is not granted as a substrate
    /// @param action The operation that failed (e.g., "enter" or "exit")
    /// @param poolAddress The address of the pool that is not supported
    error AerodromeLiquidityFuseUnsupportedPool(string action, address poolAddress);

    /// @notice Thrown when adding liquidity fails (e.g., liquidity returned is zero)
    error AerodromeLiquidityFuseAddLiquidityFailed();

    /// @notice Thrown when a token address is zero
    error AerodromeLiquidityFuseInvalidToken();

    /// @notice Thrown when the Aerodrome router address is zero
    error AerodromeLiquidityFuseInvalidRouter();
    /// @notice Event emitted when liquidity is added to an Aerodrome pool
    /// @param version The version identifier of this fuse contract
    /// @param tokenA The address of the first token in the pair
    /// @param tokenB The address of the second token in the pair
    /// @param stable Whether the pool is a stable pool (true) or volatile pool (false)
    /// @param amountA The actual amount of tokenA added
    /// @param amountB The actual amount of tokenB added
    /// @param liquidity The amount of LP tokens received
    event AerodromeLiquidityFuseEnter(
        address indexed version,
        address indexed tokenA,
        address indexed tokenB,
        bool stable,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
    );

    /// @notice Event emitted when liquidity is removed from an Aerodrome pool
    /// @param version The version identifier of this fuse contract
    /// @param tokenA The address of the first token in the pair
    /// @param tokenB The address of the second token in the pair
    /// @param stable Whether the pool is a stable pool (true) or volatile pool (false)
    /// @param amountA The amount of tokenA received
    /// @param amountB The amount of tokenB received
    /// @param liquidity The amount of LP tokens burned
    event AerodromeLiquidityFuseExit(
        address indexed version,
        address indexed tokenA,
        address indexed tokenB,
        bool stable,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
    );

    /// @notice Constructor to initialize the fuse with a market ID and router address
    /// @param marketId_ The unique identifier for the market configuration
    /// @param areodromeRouter_ The address of the Aerodrome router contract (must not be zero)
    /// @dev The market ID is used to validate that pool addresses are granted as substrates.
    ///      VERSION is set to the address of this contract instance for tracking purposes.
    /// @custom:revert AerodromeLiquidityFuseInvalidRouter When areodromeRouter_ is zero address
    constructor(uint256 marketId_, address areodromeRouter_) {
        if (areodromeRouter_ == address(0)) {
            revert AerodromeLiquidityFuseInvalidRouter();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
        AREODROME_ROUTER = areodromeRouter_;
    }

    /// @notice Adds liquidity to an Aerodrome pool
    /// @param data_ The data containing pool parameters and amounts
    /// @return response The response containing details of the added liquidity
    /// @dev Validates that token addresses are not zero and the pool is granted as a substrate.
    ///      If both desired amounts are zero, returns early without performing any operations.
    ///      After adding liquidity, resets approvals for the router to zero.
    /// @custom:revert AerodromeLiquidityFuseInvalidToken When tokenA or tokenB is zero address
    /// @custom:revert AerodromeLiquidityFuseUnsupportedPool When pool is not granted as a substrate
    /// @custom:revert AerodromeLiquidityFuseAddLiquidityFailed When liquidity returned is zero
    function enter(
        AerodromeLiquidityFuseEnterData memory data_
    ) public returns (AerodromeLiquidityFuseResponse memory response) {
        if (data_.tokenA == address(0) || data_.tokenB == address(0)) {
            revert AerodromeLiquidityFuseInvalidToken();
        }

        response.tokenA = data_.tokenA;
        response.tokenB = data_.tokenB;
        response.stable = data_.stable;

        if (data_.amountADesired == 0 && data_.amountBDesired == 0) {
            return response;
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

        (response.amountA, response.amountB, response.liquidity) = IRouter(AREODROME_ROUTER).addLiquidity(
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

        if (response.liquidity == 0) {
            revert AerodromeLiquidityFuseAddLiquidityFailed();
        }

        emit AerodromeLiquidityFuseEnter(
            VERSION,
            response.tokenA,
            response.tokenB,
            response.stable,
            response.amountA,
            response.amountB,
            response.liquidity
        );

        IERC20(data_.tokenA).forceApprove(AREODROME_ROUTER, 0);
        IERC20(data_.tokenB).forceApprove(AREODROME_ROUTER, 0);
    }

    /// @notice Removes liquidity from an Aerodrome pool
    /// @param data_ The data containing pool parameters and liquidity amount
    /// @return response The response containing details of the removed liquidity
    /// @dev Validates that token addresses are not zero and the pool is granted as a substrate.
    ///      After removing liquidity, resets approval for the router to zero.
    /// @custom:revert AerodromeLiquidityFuseInvalidToken When tokenA or tokenB is zero address
    /// @custom:revert AerodromeLiquidityFuseUnsupportedPool When pool is not granted as a substrate
    function exit(
        AerodromeLiquidityFuseExitData memory data_
    ) public returns (AerodromeLiquidityFuseResponse memory response) {
        if (data_.tokenA == address(0) || data_.tokenB == address(0)) {
            revert AerodromeLiquidityFuseInvalidToken();
        }

        response.tokenA = data_.tokenA;
        response.tokenB = data_.tokenB;
        response.stable = data_.stable;
        response.liquidity = data_.liquidity;

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

        (response.amountA, response.amountB) = IRouter(AREODROME_ROUTER).removeLiquidity(
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
            response.tokenA,
            response.tokenB,
            response.stable,
            response.amountA,
            response.amountB,
            response.liquidity
        );
    }

    /// @notice Enters the Fuse using transient storage for parameters
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        address tokenA = TypeConversionLib.toAddress(inputs[0]);
        address tokenB = TypeConversionLib.toAddress(inputs[1]);
        bool stable = TypeConversionLib.toBool(inputs[2]);
        uint256 amountADesired = TypeConversionLib.toUint256(inputs[3]);
        uint256 amountBDesired = TypeConversionLib.toUint256(inputs[4]);
        uint256 amountAMin = TypeConversionLib.toUint256(inputs[5]);
        uint256 amountBMin = TypeConversionLib.toUint256(inputs[6]);
        uint256 deadline = TypeConversionLib.toUint256(inputs[7]);

        AerodromeLiquidityFuseResponse memory response = enter(
            AerodromeLiquidityFuseEnterData({
                tokenA: tokenA,
                tokenB: tokenB,
                stable: stable,
                amountADesired: amountADesired,
                amountBDesired: amountBDesired,
                amountAMin: amountAMin,
                amountBMin: amountBMin,
                deadline: deadline
            })
        );

        bytes32[] memory outputs = new bytes32[](6);
        outputs[0] = TypeConversionLib.toBytes32(response.tokenA);
        outputs[1] = TypeConversionLib.toBytes32(response.tokenB);
        outputs[2] = TypeConversionLib.toBytes32(response.stable);
        outputs[3] = TypeConversionLib.toBytes32(response.amountA);
        outputs[4] = TypeConversionLib.toBytes32(response.amountB);
        outputs[5] = TypeConversionLib.toBytes32(response.liquidity);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits the Fuse using transient storage for parameters
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        address tokenA = TypeConversionLib.toAddress(inputs[0]);
        address tokenB = TypeConversionLib.toAddress(inputs[1]);
        bool stable = TypeConversionLib.toBool(inputs[2]);
        uint256 liquidity = TypeConversionLib.toUint256(inputs[3]);
        uint256 amountAMin = TypeConversionLib.toUint256(inputs[4]);
        uint256 amountBMin = TypeConversionLib.toUint256(inputs[5]);
        uint256 deadline = TypeConversionLib.toUint256(inputs[6]);

        AerodromeLiquidityFuseResponse memory response = exit(
            AerodromeLiquidityFuseExitData({
                tokenA: tokenA,
                tokenB: tokenB,
                stable: stable,
                liquidity: liquidity,
                amountAMin: amountAMin,
                amountBMin: amountBMin,
                deadline: deadline
            })
        );

        bytes32[] memory outputs = new bytes32[](6);
        outputs[0] = TypeConversionLib.toBytes32(response.tokenA);
        outputs[1] = TypeConversionLib.toBytes32(response.tokenB);
        outputs[2] = TypeConversionLib.toBytes32(response.stable);
        outputs[3] = TypeConversionLib.toBytes32(response.amountA);
        outputs[4] = TypeConversionLib.toBytes32(response.amountB);
        outputs[5] = TypeConversionLib.toBytes32(response.liquidity);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}

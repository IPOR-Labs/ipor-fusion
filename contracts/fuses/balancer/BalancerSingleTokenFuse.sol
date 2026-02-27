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

/**
 * @notice Data structure for entering liquidity into a Balancer pool with a single token
 * @param pool The address of the Balancer pool
 * @param tokenIn The address of the token to provide as liquidity
 * @param maxAmountIn Maximum amount of tokenIn to spend
 * @param exactBptAmountOut Exact amount of BPT (Balancer Pool Token) to receive
 */
struct BalancerSingleTokenFuseEnterData {
    address pool;
    address tokenIn;
    uint256 maxAmountIn;
    uint256 exactBptAmountOut;
}

/**
 * @notice Data structure for exiting liquidity from a Balancer pool with a single token
 * @param pool The address of the Balancer pool
 * @param tokenOut The address of the token to receive
 * @param maxBptAmountIn Maximum amount of BPT to burn
 * @param exactAmountOut Exact amount of tokenOut to receive
 */
struct BalancerSingleTokenFuseExitData {
    address pool;
    address tokenOut;
    uint256 maxBptAmountIn;
    uint256 exactAmountOut;
}

/**
 * @title BalancerSingleTokenFuse
 * @notice A fuse contract that handles single-token liquidity operations with Balancer pools
 *         within the IPOR Fusion vault system
 * @dev This contract implements the IFuseCommon interface and provides functionality for
 *      adding and removing liquidity from Balancer pools using a single token.
 *      This fuse allows for precise control over liquidity operations by specifying exact
 *      amounts for either input tokens or output BPT tokens.
 *
 * Key Features:
 * - Single token liquidity addition to Balancer pools
 * - Single token liquidity removal from Balancer pools
 * - Integration with Permit2 for gas-efficient token approvals
 * - Substrate validation to ensure only authorized pools are used
 * - Comprehensive event logging for operation tracking
 *
 * Architecture:
 * - Each fuse is tied to a specific market ID and Balancer router address
 * - Uses Permit2 for efficient token approvals without requiring separate transactions
 * - Validates pool access through the substrate system before executing operations
 * - Supports both enter and exit operations with exact amount specifications
 *
 * Security Considerations:
 * - Immutable market ID, router, and Permit2 addresses prevent configuration changes
 * - Input validation ensures pool and token addresses are not zero
 * - Substrate validation prevents unauthorized pool access
 * - Automatic approval cleanup after operations to prevent token exposure
 * - Uses SafeERC20 for secure token operations
 *
 * Usage:
 * - Enter: Provide max token amount to receive exact BPT tokens
 * - Exit: Burn max BPT tokens to receive exact underlying token amount
 */
contract BalancerSingleTokenFuse is IFuseCommon {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable BALANCER_ROUTER;
    address public immutable PERMIT2;

    /// @notice Thrown when attempting to use a pool that is not granted for this market
    /// @param pool The address of the pool that was not granted
    /// @custom:error BalancerSingleTokenFuseUnsupportedPool
    error BalancerSingleTokenFuseUnsupportedPool(address pool);

    /// @notice Thrown when invalid parameters are provided to enter or exit functions
    /// @custom:error BalancerSingleTokenFuseInvalidParams
    error BalancerSingleTokenFuseInvalidParams();

    /// @notice Thrown when an address parameter is zero
    /// @custom:error InvalidAddress
    error InvalidAddress();

    /// @notice Emitted when liquidity is added with a single token to a Balancer pool
    /// @param version The address of the fuse contract version
    /// @param pool The address of the Balancer pool
    /// @param tokenIn The address of the token that was provided as liquidity
    /// @param amountIn The actual amount of tokenIn that was spent
    /// @param exactBptAmountOut The exact amount of BPT tokens that were received
    event BalancerSingleTokenFuseEnter(
        address indexed version,
        address indexed pool,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 exactBptAmountOut
    );

    /// @notice Emitted when liquidity is removed with a single token from a Balancer pool
    /// @param version The address of the fuse contract version
    /// @param pool The address of the Balancer pool
    /// @param tokenOut The address of the token that was received
    /// @param bptAmountIn The actual amount of BPT tokens that were burned
    /// @param exactAmountOut The exact amount of tokenOut that was received
    event BalancerSingleTokenFuseExit(
        address indexed version,
        address indexed pool,
        address indexed tokenOut,
        uint256 bptAmountIn,
        uint256 exactAmountOut
    );

    /// @notice Constructor to initialize the fuse with market ID, Balancer router, and Permit2 addresses
    /// @param marketId_ The unique identifier for the market configuration
    /// @param balancerRouter_ The address of the Balancer router contract
    /// @param permit2_ The address of the Permit2 contract for gas-efficient token approvals
    /// @dev The market ID is used to retrieve the list of substrates (pools) that this fuse will track.
    ///      VERSION is set to the address of this contract instance for tracking purposes.
    ///      Router address must be non-zero.
    constructor(uint256 marketId_, address balancerRouter_, address permit2_) {
        if (balancerRouter_ == address(0)) {
            revert InvalidAddress();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        BALANCER_ROUTER = balancerRouter_;
        PERMIT2 = permit2_;
    }

    /// @notice Adds single token liquidity into a Balancer V3 pool
    /// @param data_ Parameters for single token liquidity addition
    /// @return amountIn The actual amount of tokenIn that was spent
    /// @dev Validates pool substrate, token in pool, and ensures proper approval cleanup.
    ///      Uses Permit2 for gas-efficient token approvals. Returns 0 if maxAmountIn is 0.
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

    /// @notice Removes single token liquidity from a Balancer V3 pool
    /// @param data_ Parameters for single token liquidity removal
    /// @return bptAmountIn The actual amount of BPT tokens that were burned
    /// @dev Validates pool substrate and ensures proper approval cleanup.
    ///      Returns 0 if maxBptAmountIn is 0.
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

        // Validate that the output token is granted as a TOKEN substrate for this market
        // This prevents withdrawing non-whitelisted tokens into the vault
        BalancerSubstrateLib.validateTokenGranted(MARKET_ID, data_.tokenOut);

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

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

/**
 * @notice Data structure for entering liquidity into a Balancer pool with unbalanced amounts
 * @param pool The address of the Balancer pool
 * @param tokens Array of token addresses to provide liquidity for
 * @param exactAmountsIn Array of exact token amounts to provide (must match tokens array length)
 * @param minBptAmountOut Minimum BPT (Balancer Pool Token) amount to receive
 */
struct BalancerLiquidityUnbalancedFuseEnterData {
    address pool;
    address[] tokens;
    uint256[] exactAmountsIn;
    uint256 minBptAmountOut;
}

/**
 * @notice Data structure for exiting liquidity from a Balancer pool
 * @param pool The address of the Balancer pool
 * @param maxBptAmountIn Maximum BPT amount to burn for withdrawal
 * @param minAmountsOut Array of minimum token amounts to receive for each token
 */
struct BalancerLiquidityUnbalancedFuseExitData {
    address pool;
    uint256 maxBptAmountIn;
    uint256[] minAmountsOut;
}

/**
 * @title BalancerLiquidityUnbalancedFuse
 * @notice A fuse contract that handles unbalanced liquidity operations with Balancer pools
 *         within the IPOR Fusion vault system
 * @dev This contract implements the IFuseCommon interface and provides functionality for
 *      adding and removing liquidity from Balancer pools with custom token amounts.
 *      Unlike proportional liquidity operations, this fuse allows for unbalanced deposits
 *      and withdrawals, providing more flexibility in liquidity management.
 *
 * Key Features:
 * - Unbalanced liquidity addition to Balancer pools
 * - Custom liquidity removal from Balancer pools
 * - Integration with Permit2 for gas-efficient token approvals
 * - Substrate validation to ensure only authorized pools are used
 * - Comprehensive event logging for operation tracking
 *
 * Architecture:
 * - Each fuse is tied to a specific market ID and Balancer router address
 * - Uses Permit2 for efficient token approvals without requiring separate transactions
 * - Validates pool access through the substrate system before executing operations
 * - Supports both enter and exit operations with custom token amounts
 *
 * Security Considerations:
 * - Immutable market ID, router, and Permit2 addresses prevent configuration changes
 * - Input validation ensures pool addresses are not zero and array lengths match
 * - Substrate validation prevents unauthorized pool access
 * - Automatic approval cleanup after operations to prevent token exposure
 * - Uses SafeERC20 for secure token operations
 *
 * Usage:
 * - Enter: Provide exact token amounts to receive BPT tokens
 * - Exit: Burn BPT tokens to receive underlying tokens with minimum amounts specified
 */
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

        BalancerSubstrateLib.checkTokensInPool(data_.pool, data_.tokens);

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
                IERC20(data_.tokens[i]).forceApprove(PERMIT2, 0);
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

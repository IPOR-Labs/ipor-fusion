// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

import {IRouter} from "./ext/IRouter.sol";
import {IPermit2} from "./ext/IPermit2.sol";
import {BalancerSubstrateLib, BalancerSubstrateType, BalancerSubstrate} from "./BalancerSubstrateLib.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Data required to add liquidity proportionally into a Balancer V3 pool
struct BalancerLiquidityProportionalFuseEnterData {
    /// @notice Pool address
    address pool;
    /// @notice Pool tokens in token registration order
    address[] tokens;
    /// @notice Maximum amounts of tokens to be added, sorted in token registration order
    uint256[] maxAmountsIn;
    /// @notice Exact amount of BPT to mint
    uint256 exactBptAmountOut;
}

struct BalancerLiquidityProportionalFuseExitData {
    /// @notice Pool address (also the BPT token)
    address pool;
    /// @notice Exact amount of BPT to burn
    uint256 exactBptAmountIn;
    /// @notice Minimum amounts of tokens to receive, in token registration order
    uint256[] minAmountsOut;
}
/// @title BalancerLiquidityProportionalFuse
/// @notice Fuse that adds/removes liquidity proportionally to/from a Balancer V3 pool via Router API
contract BalancerLiquidityProportionalFuse is IFuseCommon {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable BALANCER_ROUTER;
    address public immutable PERMIT2;

    error BalancerLiquidityProportionalFuseUnsupportedPool(address pool);
    error BalancerLiquidityProportionalFuseInvalidParams();
    error InvalidAddress();

    event BalancerLiquidityProportionalFuseEnter(
        address indexed version,
        address indexed pool,
        uint256[] amountsIn,
        uint256 exactBptAmountOut
    );

    event BalancerLiquidityProportionalFuseExit(
        address indexed version,
        address indexed pool,
        uint256[] amountsOut,
        uint256 exactBptAmountIn
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

    /// @notice Adds liquidity proportionally into a Balancer V3 pool
    /// @param data_ Encoded parameters required by the Balancer Router
    function enter(BalancerLiquidityProportionalFuseEnterData calldata data_) external payable {
        if (data_.pool == address(0)) {
            revert BalancerLiquidityProportionalFuseInvalidParams();
        }
        if (data_.tokens.length != data_.maxAmountsIn.length) {
            revert BalancerLiquidityProportionalFuseInvalidParams();
        }

        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                BalancerSubstrateLib.substrateToBytes32(
                    BalancerSubstrate({substrateType: BalancerSubstrateType.POOL, substrateAddress: data_.pool})
                )
            )
        ) {
            revert BalancerLiquidityProportionalFuseUnsupportedPool(data_.pool);
        }

        uint256 len = data_.tokens.length;
        for (uint256 i; i < len; ++i) {
            uint256 amountIn = data_.maxAmountsIn[i];
            if (amountIn > 0) {
                IERC20(data_.tokens[i]).forceApprove(PERMIT2, amountIn);
                IPermit2(PERMIT2).approve(
                    data_.tokens[i],
                    BALANCER_ROUTER,
                    amountIn.toUint160(),
                    uint48(block.timestamp + 1)
                );
            }
        }

        uint256[] memory amountsIn = IRouter(BALANCER_ROUTER).addLiquidityProportional(
            data_.pool,
            data_.maxAmountsIn,
            data_.exactBptAmountOut,
            false,
            ""
        );

        emit BalancerLiquidityProportionalFuseEnter(VERSION, data_.pool, amountsIn, data_.exactBptAmountOut);

        for (uint256 i; i < len; ++i) {
            if (data_.maxAmountsIn[i] > 0) {
                IERC20(data_.tokens[i]).forceApprove(BALANCER_ROUTER, 0);
            }
        }
    }

    /// @notice Removes liquidity proportionally from a Balancer V3 pool
    /// @param data_ Parameters for proportional liquidity removal
    function exit(BalancerLiquidityProportionalFuseExitData calldata data_) external payable {
        if (data_.pool == address(0)) {
            revert BalancerLiquidityProportionalFuseInvalidParams();
        }

        // Access control: pool must be granted as a substrate for this market
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                BalancerSubstrateLib.substrateToBytes32(
                    BalancerSubstrate({substrateType: BalancerSubstrateType.POOL, substrateAddress: data_.pool})
                )
            )
        ) {
            revert BalancerLiquidityProportionalFuseUnsupportedPool(data_.pool);
        }

        if (data_.exactBptAmountIn == 0) {
            return;
        }

        // Approve BPT (pool token) to router for burning
        IERC20(data_.pool).forceApprove(BALANCER_ROUTER, data_.exactBptAmountIn);

        uint256[] memory amountsOut = IRouter(BALANCER_ROUTER).removeLiquidityProportional(
            data_.pool,
            data_.exactBptAmountIn,
            data_.minAmountsOut,
            false,
            ""
        );

        emit BalancerLiquidityProportionalFuseExit(VERSION, data_.pool, amountsOut, data_.exactBptAmountIn);

        IERC20(data_.pool).forceApprove(BALANCER_ROUTER, 0);
    }
}

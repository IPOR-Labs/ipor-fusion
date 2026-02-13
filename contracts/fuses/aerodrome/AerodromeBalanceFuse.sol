// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IPool} from "./ext/IPool.sol";
import {IGauge} from "./ext/IGauge.sol";
import {AerodromeSubstrateLib, AerodromeSubstrate, AerodromeSubstrateType} from "./AreodromeLib.sol";

/// @title AerodromeBalanceFuse
/// @notice Calculates the USD value of Plasma Vault positions in Aerodrome pools and gauges
/// @dev This fuse only calculates LIQUIDITY value (LP token value based on reserves).
///      REWARDS (AERO emissions) are NOT included - they are handled separately by RewardsManager and reward fuses.
///      TRADING FEES for pool positions are included as they accrue directly to LP holders.
///      For gauge positions, trading fees go to veAERO voters (not stakers), so they are not counted.
/// @author IPOR Labs
contract AerodromeBalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;

    /// @notice Custom error thrown when a pool has invalid token addresses (zero address)
    error InvalidPool();

    /// @notice The address of this fuse version for tracking purposes
    address public immutable VERSION;

    /// @notice The market ID associated with this fuse
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @return The balance of the Plasma Vault in USD, represented in 18 decimals
    /// @dev For Pool positions: LP value + trading fees
    ///      For Gauge positions: LP value only (rewards handled by RewardsManager)
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = substrates.length;

        if (len == 0) {
            return 0;
        }

        uint256 balance;
        address pool;
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();
        uint256 liquidity;
        AerodromeSubstrate memory substrate;
        bool isGauge;

        for (uint256 i; i < len; ++i) {
            substrate = AerodromeSubstrateLib.bytes32ToSubstrate(substrates[i]);

            if (substrate.substrateType == AerodromeSubstrateType.Gauge) {
                // GAUGE: Only liquidity value (rewards handled by RewardsManager)
                pool = IGauge(substrate.substrateAddress).stakingToken();
                liquidity = IERC20(substrate.substrateAddress).balanceOf(address(this));

                if (liquidity > 0) {
                    balance += _calculateBalanceFromLiquidity(pool, priceOracleMiddleware, liquidity);
                }
                // NOTE: AERO emissions are NOT counted here - use AerodromeGaugeClaimFuse
                // and RewardsManager to handle rewards separately
            } else if (substrate.substrateType == AerodromeSubstrateType.Pool) {
                // POOL: Liquidity value + trading fees
                pool = substrate.substrateAddress;
                liquidity = IERC20(pool).balanceOf(address(this));

                if (liquidity > 0) {
                    balance += _calculateBalanceFromLiquidity(pool, priceOracleMiddleware, liquidity);
                }
                // Always calculate fees - claimable fees may exist even when liquidity is zero
                // (e.g., after withdrawing LP tokens but before claiming accumulated fees)
                balance += _calculateBalanceFromFees(pool, priceOracleMiddleware, liquidity);
            }
        }

        return balance;
    }

    /// @notice Calculates the USD value of LP tokens based on underlying pool reserves
    /// @dev This function implements the balance calculation methodology for liquidity positions:
    ///      1. Retrieves the two tokens (token0 and token1) that make up the pool
    ///      2. Gets the current reserves of both tokens in the pool
    ///      3. Gets the total supply of LP tokens for the pool
    ///      4. Calculates the proportional share of reserves:
    ///         amount0 = (liquidity_ * reserve0) / totalSupply
    ///         amount1 = (liquidity_ * reserve1) / totalSupply
    ///      5. Retrieves USD prices for both tokens from the price oracle middleware
    ///      6. Converts each token amount to USD value and normalizes to WAD (18 decimals)
    ///      The calculation assumes that LP tokens represent a proportional share of the pool's reserves.
    ///      If totalSupply is zero, the function returns 0 to prevent division by zero.
    /// @param pool_ The address of the Aerodrome pool
    /// @param priceOracleMiddleware_ The address of the price oracle middleware for USD price conversion
    /// @param liquidity_ The amount of LP tokens held by the vault
    /// @return balanceInUsd The USD value of the LP tokens, normalized to WAD (18 decimals)
    function _calculateBalanceFromLiquidity(
        address pool_,
        address priceOracleMiddleware_,
        uint256 liquidity_
    ) private view returns (uint256 balanceInUsd) {
        address token0 = IPool(pool_).token0();
        address token1 = IPool(pool_).token1();

        if (token0 == address(0) || token1 == address(0)) {
            revert InvalidPool();
        }

        (uint256 reserve0, uint256 reserve1, ) = IPool(pool_).getReserves();
        uint256 totalSupply = IERC20(pool_).totalSupply();

        // Prevent division by zero: if totalSupply is zero, return 0 balance
        if (totalSupply == 0) {
            return 0;
        }

        uint256 amount0 = (liquidity_ * reserve0) / totalSupply;
        uint256 amount1 = (liquidity_ * reserve1) / totalSupply;

        (uint256 price0, uint256 priceDecimals0) = IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(token0);
        (uint256 price1, uint256 priceDecimals1) = IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(token1);

        balanceInUsd += IporMath.convertToWad(amount0 * price0, IERC20Metadata(token0).decimals() + priceDecimals0);
        balanceInUsd += IporMath.convertToWad(amount1 * price1, IERC20Metadata(token1).decimals() + priceDecimals1);

        return balanceInUsd;
    }

    /// @notice Calculates the USD value of accumulated fees from the pool using index delta calculations
    /// @dev This function implements the fee calculation logic using index deltas:
    ///      Fee Accumulation Mechanism:
    ///      - Aerodrome pools track fees using two indices per token (index0 and index1)
    ///      - Each pool maintains a global index that accumulates fees over time
    ///      - Each liquidity provider has a supplyIndex that tracks their last checkpoint
    ///      - The difference (delta) between current index and supplyIndex represents accumulated fees
    ///
    ///      Index Delta Calculation:
    ///      1. Retrieves the current global indices (index0, index1) from the pool
    ///      2. Retrieves the vault's last checkpoint indices (supplyIndex0, supplyIndex1)
    ///      3. Calculates deltas: delta0 = index0 - supplyIndex0, delta1 = index1 - supplyIndex1
    ///      4. The delta represents the fee growth per unit of liquidity since last checkpoint
    ///
    ///      Fee Amount Calculation:
    ///      1. Gets already claimable fees (claimable0, claimable1) that haven't been claimed yet
    ///      2. Calculates additional fees from index deltas:
    ///         additionalFees0 = (liquidity_ * delta0) / 1e18
    ///         additionalFees1 = (liquidity_ * delta1) / 1e18
    ///      3. Total claimable = already claimable + additional fees from deltas
    ///      4. Converts claimable amounts to USD using price oracle middleware
    ///      5. Normalizes to WAD (18 decimals) and returns total USD value
    ///
    ///      The index delta approach ensures accurate fee tracking even if fees accumulate between balance checks.
    ///      Only positive deltas are considered to avoid underflow issues.
    ///
    ///      IMPORTANT: This function should only be called for Pool substrates where the vault directly holds
    ///      LP tokens. For Gauge substrates, trading fees go to the FeesVotingReward contract (voter/bribe system),
    ///      not to the vault, so this function should not be called.
    /// @param pool_ The address of the Aerodrome pool
    /// @param priceOracleMiddleware_ The address of the price oracle middleware for USD price conversion
    /// @param liquidity_ The amount of LP tokens held by the vault
    /// @return balanceInUsd The USD value of accumulated fees, normalized to WAD (18 decimals)
    function _calculateBalanceFromFees(
        address pool_,
        address priceOracleMiddleware_,
        uint256 liquidity_
    ) private view returns (uint256 balanceInUsd) {
        address plasmaVault = address(this);
        uint256 supplyIndex0 = IPool(pool_).supplyIndex0(plasmaVault);
        uint256 supplyIndex1 = IPool(pool_).supplyIndex1(plasmaVault);
        uint256 index0 = IPool(pool_).index0();
        uint256 index1 = IPool(pool_).index1();

        // Calculate index deltas: difference between current global index and vault's last checkpoint
        uint256 delta0 = index0 - supplyIndex0;
        uint256 delta1 = index1 - supplyIndex1;

        // Get already claimable fees that haven't been claimed yet
        uint256 claimable0 = IPool(pool_).claimable0(plasmaVault);
        uint256 claimable1 = IPool(pool_).claimable1(plasmaVault);

        // Add fees accumulated since last checkpoint using index deltas
        // delta represents fee growth per unit of liquidity, multiplied by liquidity to get total fees
        if (delta0 > 0) {
            claimable0 += (liquidity_ * delta0) / 1e18;
        }

        if (delta1 > 0) {
            claimable1 += (liquidity_ * delta1) / 1e18;
        }

        // Convert claimable fees to USD value
        if (claimable0 > 0) {
            address token0 = IPool(pool_).token0();
            (uint256 price0, uint256 priceDecimals0) = IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(
                token0
            );
            balanceInUsd += IporMath.convertToWad(
                claimable0 * price0,
                IERC20Metadata(token0).decimals() + priceDecimals0
            );
        }

        if (claimable1 > 0) {
            address token1 = IPool(pool_).token1();
            (uint256 price1, uint256 priceDecimals1) = IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(
                token1
            );
            balanceInUsd += IporMath.convertToWad(
                claimable1 * price1,
                IERC20Metadata(token1).decimals() + priceDecimals1
            );
        }

        return balanceInUsd;
    }
}

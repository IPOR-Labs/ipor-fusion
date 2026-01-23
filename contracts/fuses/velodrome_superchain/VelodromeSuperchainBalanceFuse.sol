// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPool} from "./ext/IPool.sol";
import {ILeafGauge} from "./ext/ILeafGauge.sol";
import {VelodromeSuperchainSubstrateLib, VelodromeSuperchainSubstrate, VelodromeSuperchainSubstrateType} from "./VelodromeSuperchainLib.sol";

/// @title VelodromeSuperchainBalanceFuse
/// @notice Contract responsible for managing Velodrome Basic Vault balance calculations
/// @dev This contract handles balance tracking for Plasma Vault positions in Velodrome pools and gauges
/// It calculates total USD value of vault's liquidity positions and accrued fees across multiple Velodrome substrates
/// The balance calculations support both direct pool positions and staked gauge positions

contract VelodromeSuperchainBalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;

    error InvalidPool();

    /// @notice Address of this fuse contract version
    /// @dev Immutable value set in constructor, used for tracking and versioning
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    /// @dev Immutable value set in constructor, used to retrieve market substrates (Velodrome pool and gauge addresses)
    uint256 public immutable MARKET_ID;

    /**
     * @notice Initializes the VelodromeSuperchainBalanceFuse with a market ID
     * @param marketId_ The market ID used to identify the market and retrieve substrates
     */
    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @return The balance of the Plasma Vault in associated with Fuse Balance marketId in USD, represented in 18 decimals
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory pools = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = pools.length;

        if (len == 0) {
            return 0;
        }

        uint256 balance;
        address pool;
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();
        uint256 liquidity;
        VelodromeSuperchainSubstrate memory substrate;

        for (uint256 i; i < len; ++i) {
            substrate = VelodromeSuperchainSubstrateLib.bytes32ToSubstrate(pools[i]);

            if (substrate.substrateType == VelodromeSuperchainSubstrateType.Gauge) {
                address gauge = substrate.substrateAddress;
                pool = ILeafGauge(gauge).stakingToken();
                liquidity = IERC20(gauge).balanceOf(address(this));

                if (liquidity > 0) {
                    balance += _calculateBalanceFromLiquidity(pool, priceOracleMiddleware, liquidity);
                    // For gauge positions: use gauge's fee caches prorated by vault's share
                    balance += _calculateBalanceFromGaugeFees(gauge, pool, priceOracleMiddleware);
                }
            } else if (substrate.substrateType == VelodromeSuperchainSubstrateType.Pool) {
                pool = substrate.substrateAddress;
                liquidity = IERC20(pool).balanceOf(address(this));

                if (liquidity > 0) {
                    balance += _calculateBalanceFromLiquidity(pool, priceOracleMiddleware, liquidity);
                    // For pool positions: use pool's fee indices keyed to vault address
                    balance += _calculateBalanceFromPoolFees(pool, priceOracleMiddleware, liquidity);
                }
            }
        }
        return balance;
    }

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

        uint256 amount0 = (liquidity_ * reserve0) / totalSupply;
        uint256 amount1 = (liquidity_ * reserve1) / totalSupply;

        (uint256 price0, uint256 priceDecimals0) = IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(token0);
        (uint256 price1, uint256 priceDecimals1) = IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(token1);

        balanceInUsd += IporMath.convertToWad(amount0 * price0, IERC20Metadata(token0).decimals() + priceDecimals0);
        balanceInUsd += IporMath.convertToWad(amount1 * price1, IERC20Metadata(token1).decimals() + priceDecimals1);
        return balanceInUsd;
    }

    /// @notice Calculate fee balance for direct pool positions (LP tokens held by vault in the pool)
    /// @dev For pool positions, fees accrue directly to the vault address in the pool's fee tracking
    /// @param pool_ The pool address
    /// @param priceOracleMiddleware_ The price oracle middleware address
    /// @param liquidity_ The vault's LP token balance in the pool
    /// @return balanceInUsd The USD value of accrued fees
    function _calculateBalanceFromPoolFees(
        address pool_,
        address priceOracleMiddleware_,
        uint256 liquidity_
    ) private view returns (uint256 balanceInUsd) {
        address plasmaVault = address(this);
        uint256 supplyIndex0 = IPool(pool_).supplyIndex0(plasmaVault);
        uint256 supplyIndex1 = IPool(pool_).supplyIndex1(plasmaVault);
        uint256 index0 = IPool(pool_).index0();
        uint256 index1 = IPool(pool_).index1();

        uint256 delta0 = index0 - supplyIndex0;
        uint256 delta1 = index1 - supplyIndex1;

        uint256 claimable0 = IPool(pool_).claimable0(plasmaVault);
        uint256 claimable1 = IPool(pool_).claimable1(plasmaVault);

        if (delta0 > 0) {
            claimable0 += (liquidity_ * delta0) / 1e18;
        }

        if (delta1 > 0) {
            claimable1 += (liquidity_ * delta1) / 1e18;
        }
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

    /// @notice Calculate fee balance for gauge-staked positions
    /// @dev When LP tokens are staked in a gauge, the pool accrues fees to the gauge (or its feesVotingReward),
    ///      not to the original depositor. This function uses the gauge's cached fee amounts (fees0/fees1)
    ///      and prorates them by the vault's share of the gauge's total staked supply.
    /// @param gauge_ The gauge address where LP tokens are staked
    /// @param pool_ The underlying pool address (for token addresses)
    /// @param priceOracleMiddleware_ The price oracle middleware address
    /// @return balanceInUsd The USD value of the vault's prorated share of gauge fees
    function _calculateBalanceFromGaugeFees(
        address gauge_,
        address pool_,
        address priceOracleMiddleware_
    ) private view returns (uint256 balanceInUsd) {
        uint256 gaugeTotalSupply = ILeafGauge(gauge_).totalSupply();

        // If no one has staked in the gauge, there are no fees to prorate
        if (gaugeTotalSupply == 0) {
            return 0;
        }

        uint256 vaultStake = ILeafGauge(gauge_).balanceOf(address(this));

        // Get the gauge's cached fee amounts
        uint256 gaugeFees0 = ILeafGauge(gauge_).fees0();
        uint256 gaugeFees1 = ILeafGauge(gauge_).fees1();

        // Prorate fees by vault's share of the gauge
        uint256 vaultFees0 = (gaugeFees0 * vaultStake) / gaugeTotalSupply;
        uint256 vaultFees1 = (gaugeFees1 * vaultStake) / gaugeTotalSupply;

        if (vaultFees0 > 0) {
            address token0 = IPool(pool_).token0();
            (uint256 price0, uint256 priceDecimals0) = IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(
                token0
            );
            balanceInUsd += IporMath.convertToWad(
                vaultFees0 * price0,
                IERC20Metadata(token0).decimals() + priceDecimals0
            );
        }

        if (vaultFees1 > 0) {
            address token1 = IPool(pool_).token1();
            (uint256 price1, uint256 priceDecimals1) = IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(
                token1
            );
            balanceInUsd += IporMath.convertToWad(
                vaultFees1 * price1,
                IERC20Metadata(token1).decimals() + priceDecimals1
            );
        }

        return balanceInUsd;
    }
}

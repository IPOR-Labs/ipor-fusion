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
/// @notice Calculates the USD value of Plasma Vault positions in Velodrome Superchain pools and gauges
/// @dev This fuse only calculates LIQUIDITY value (LP token value based on reserves).
///      REWARDS (VELO emissions) are NOT included - they are handled separately by RewardsManager and reward fuses.
///      TRADING FEES for pool positions are included as they accrue directly to LP holders.
///      For gauge positions, trading fees go to veVELO voters (not stakers), so they are not counted.
/// @author IPOR Labs
contract VelodromeSuperchainBalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;

    error InvalidPool();

    /// @notice Address of this fuse contract version
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
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
        if (len == 0) return 0;

        uint256 balance;
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();
        VelodromeSuperchainSubstrate memory substrate;

        for (uint256 i; i < len; ++i) {
            substrate = VelodromeSuperchainSubstrateLib.bytes32ToSubstrate(substrates[i]);
            address substrateAddress = substrate.substrateAddress;

            if (substrate.substrateType == VelodromeSuperchainSubstrateType.Gauge) {
                // GAUGE: Only liquidity value (rewards handled by RewardsManager)
                address pool = ILeafGauge(substrateAddress).stakingToken();
                uint256 liquidity = ILeafGauge(substrateAddress).balanceOf(address(this));

                if (liquidity > 0) {
                    balance += _calculateBalanceFromLiquidity(pool, priceOracleMiddleware, liquidity);
                }
                // NOTE: VELO emissions are NOT counted here - use VelodromeSuperchainGaugeClaimFuse
                // and RewardsManager to handle rewards separately
            } else if (substrate.substrateType == VelodromeSuperchainSubstrateType.Pool) {
                // POOL: Liquidity value + trading fees
                uint256 liquidity = IERC20(substrateAddress).balanceOf(address(this));

                if (liquidity > 0) {
                    balance += _calculateBalanceFromLiquidity(substrateAddress, priceOracleMiddleware, liquidity);
                }
                // Always calculate fees - claimable fees may exist even when liquidity is zero
                // (e.g., after withdrawing LP tokens but before claiming accumulated fees)
                balance += _calculateBalanceFromPoolFees(substrateAddress, priceOracleMiddleware, liquidity);
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
}

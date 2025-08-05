// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IPool} from "./ext/IPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGauge} from "./ext/IGauge.sol";
import {AerodromeSubstrateLib, AerodromeSubstrate, AerodromeSubstrateType} from "./AreodromeLib.sol";

contract AerodromeBalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;

    error InvalidPool();

    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
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
        AerodromeSubstrate memory substrate;

        for (uint256 i; i < len; ++i) {
            substrate = AerodromeSubstrateLib.bytes32ToSubstrate(pools[i]);

            if (substrate.substrateType == AerodromeSubstrateType.Gauge) {
                pool = IGauge(substrate.substrateAddress).stakingToken();
                liquidity = IERC20(substrate.substrateAddress).balanceOf(address(this));
            } else if (substrate.substrateType == AerodromeSubstrateType.Pool) {
                pool = substrate.substrateAddress;
                liquidity = IERC20(pool).balanceOf(address(this));
            } else {
                continue;
            }

            if (liquidity > 0) {
                balance += _calculateBalanceFromLiquidity(pool, priceOracleMiddleware, liquidity);
                balance += _calculateBalanceFromFees(pool, priceOracleMiddleware, liquidity);
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

    function substratesToBytes32(AerodromeSubstrate[] memory substrates_) private pure returns (bytes32[] memory) {
        bytes32[] memory bytes32Substrates = new bytes32[](substrates_.length);
        for (uint256 i; i < substrates_.length; ++i) {
            bytes32Substrates[i] = AerodromeSubstrateLib.substrateToBytes32(substrates_[i]);
        }
        return bytes32Substrates;
    }

    function bytes32ToSubstrate(
        bytes32[] memory bytes32Substrates_
    ) private pure returns (AerodromeSubstrate[] memory) {
        AerodromeSubstrate[] memory substrates = new AerodromeSubstrate[](bytes32Substrates_.length);
        for (uint256 i; i < bytes32Substrates_.length; ++i) {
            substrates[i] = AerodromeSubstrateLib.bytes32ToSubstrate(bytes32Substrates_[i]);
        }
        return substrates;
    }
}

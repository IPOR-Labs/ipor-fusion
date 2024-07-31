// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IMarketBalanceFuse} from "./../IMarketBalanceFuse.sol";
import {IporMath} from "./../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "./../../libraries/PlasmaVaultConfigLib.sol";
import {IChildLiquidityGauge} from "./ext/IChildLiquidityGauge.sol";
import {ICurveStableswapNG} from "./../curve_stableswap_ng/ext/ICurveStableswapNG.sol";
import {IPriceOracleMiddleware} from "./../../priceOracle/IPriceOracleMiddleware.sol";

contract CurveChildLiquidityGaugeBalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    uint256 private constant PRICE_DECIMALS = 8;

    uint256 public immutable MARKET_ID;
    IPriceOracleMiddleware public immutable PRICE_ORACLE;

    error AssetNotFoundInCurvePool(address curvePool, address asset);

    constructor(uint256 marketIdInput_, address priceOracle_) {
        MARKET_ID = marketIdInput_;
        PRICE_ORACLE = IPriceOracleMiddleware(priceOracle_);
    }
    /// @notice Returns the value of the LP tokens staked in the Curve pool
    /// @notice Rewards are not included here
    /// @notice Value of LP tokens is estimated based on the amount of the underluing that can be withdrawn
    /// @param plasmaVault_ Plasma Vault address
    /// @return balance_ Plasma Vault balance
    function balanceOf(address plasmaVault_) external view override returns (uint256) {
        /// @notice substrates below are the Curve staked LP tokens
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = substrates.length;
        if (len == 0) {
            return 0;
        }

        uint256 balance;
        uint256 withdrawTokenAmount; // underlying asset of the vault amount to withdraw from LP
        address vaultUnderlyingAsset = IERC4626(plasmaVault_).asset(); // Plasma Vault asset
        address stakedLpTokenAddress;
        address lpTokenAddress; // Curve LP token
        int128 indexCoin; // index of the underlying asset in the Curve pool

        for (uint256 i; i < len; ++i) {
            stakedLpTokenAddress = PlasmaVaultConfigLib.bytes32ToAddress(substrates[i]);
            lpTokenAddress = IChildLiquidityGauge(stakedLpTokenAddress).lp_token();
            indexCoin = _getCoinIndex(ICurveStableswapNG(lpTokenAddress), vaultUnderlyingAsset);
            withdrawTokenAmount = ICurveStableswapNG(lpTokenAddress).calc_withdraw_one_coin(
                ERC20(lpTokenAddress).balanceOf(plasmaVault_),
                indexCoin
            );
            balance += IporMath.convertToWad(
                withdrawTokenAmount * PRICE_ORACLE.getAssetPrice(vaultUnderlyingAsset),
                ERC20(IERC4626(plasmaVault_).asset()).decimals() + PRICE_DECIMALS
            );
        }
        return balance;
    }

    function _getCoinIndex(ICurveStableswapNG curvePool_, address asset_) internal view returns (int128) {
        uint256 len = curvePool_.N_COINS();
        for (uint256 j; j < len; ++j) {
            if (curvePool_.coins(j) == asset_) {
                return SafeCast.toInt128(int256(j));
            }
        }
        revert AssetNotFoundInCurvePool(address(curvePool_), asset_);
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IMarketBalanceFuse} from "./../IMarketBalanceFuse.sol";
import {IporMath} from "./../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "./../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "./../../libraries/PlasmaVaultLib.sol";
import {IChildLiquidityGauge} from "./ext/IChildLiquidityGauge.sol";
import {ICurveStableswapNG} from "./../curve_stableswap_ng/ext/ICurveStableswapNG.sol";
import {IPriceOracleMiddleware} from "./../../price_oracle/IPriceOracleMiddleware.sol";

contract CurveChildLiquidityGaugeBalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;

    uint256 public immutable MARKET_ID;

    error AssetNotFoundInCurvePool(address curvePool, address asset);

    constructor(uint256 marketIdInput_) {
        MARKET_ID = marketIdInput_;
    }
    /// @notice Returns the value of the LP tokens staked in the Curve pool
    /// @notice Rewards are not included here
    /// @notice Value of LP tokens is estimated based on the amount of the underluing that can be withdrawn
    /// @return balance_ Plasma Vault balance
    function balanceOf() external view override returns (uint256) {
        /// @notice substrates below are the Curve staked LP tokens
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = substrates.length;

        if (len == 0) {
            return 0;
        }

        uint256 balance;
        uint256 stakedLPTokenBalance;
        uint256 withdrawUnderlyingTokenAmount; /// @dev underlying asset of the vault amount to withdraw from LP
        address plasmaVault = address(this);
        address plasmaVaultAsset = IERC4626(plasmaVault).asset();
        uint256 plasmaVaultAssetPriceDecimals = ERC20(plasmaVaultAsset).decimals();
        address stakedLpTokenAddress;
        address lpTokenAddress; /// @dev Curve LP token
        int128 indexCoin; /// @dev index of the underlying asset in the Curve pool

        (uint256 assetPriceInUSD, uint256 priceDecimals) = IPriceOracleMiddleware(
            PlasmaVaultLib.getPriceOracleMiddleware()
        ).getAssetPrice(plasmaVaultAsset);

        for (uint256 i; i < len; ++i) {
            stakedLpTokenAddress = PlasmaVaultConfigLib.bytes32ToAddress(substrates[i]);
            lpTokenAddress = IChildLiquidityGauge(stakedLpTokenAddress).lp_token();
            indexCoin = _getCoinIndex(ICurveStableswapNG(lpTokenAddress), plasmaVaultAsset);
            stakedLPTokenBalance = ERC20(stakedLpTokenAddress).balanceOf(plasmaVault);
            if (stakedLPTokenBalance > 0) {
                withdrawUnderlyingTokenAmount = ICurveStableswapNG(lpTokenAddress).calc_withdraw_one_coin(
                    stakedLPTokenBalance,
                    indexCoin
                );
                balance += IporMath.convertToWad(
                    withdrawUnderlyingTokenAmount * assetPriceInUSD,
                    plasmaVaultAssetPriceDecimals + priceDecimals
                );
            }
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

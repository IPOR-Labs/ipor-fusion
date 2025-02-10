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
import {IPriceOracleMiddleware} from "./../../price_oracle/IPriceOracleMiddleware.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

contract CurveChildLiquidityGaugeErc4626BalanceFuse is IMarketBalanceFuse {
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
        address gaugeAddress;
        address lpTokenAddress; /// @dev Curve LP token
        uint256 assetPriceInUSD;
        uint256 priceDecimals;

        IPriceOracleMiddleware priceOracleMiddleware = IPriceOracleMiddleware(
            PlasmaVaultLib.getPriceOracleMiddleware()
        );

        for (uint256 i; i < len; ++i) {
            gaugeAddress = PlasmaVaultConfigLib.bytes32ToAddress(substrates[i]);
            lpTokenAddress = IChildLiquidityGauge(gaugeAddress).lp_token();
            /// @dev The balance in the Gauge contract is 1:1 with LP tokens - staking does not change the token ratio
            stakedLPTokenBalance = IChildLiquidityGauge(gaugeAddress).balanceOf(plasmaVault);
            if (stakedLPTokenBalance > 0) {
                withdrawUnderlyingTokenAmount = ERC4626Upgradeable(lpTokenAddress).convertToAssets(
                    stakedLPTokenBalance
                );
                if (withdrawUnderlyingTokenAmount > 0) {
                    (assetPriceInUSD, priceDecimals) = priceOracleMiddleware.getAssetPrice(plasmaVaultAsset);
                    balance += IporMath.convertToWad(
                        withdrawUnderlyingTokenAmount * assetPriceInUSD,
                        plasmaVaultAssetPriceDecimals + priceDecimals
                    );
                }
            }
        }
        return balance;
    }
}

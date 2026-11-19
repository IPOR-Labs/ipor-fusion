// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {ISiloConfig} from "./ext/ISiloConfig.sol";
import {ISilo} from "./ext/ISilo.sol";
import {IShareToken} from "./ext/IShareToken.sol";

/// @title SiloV2BalanceFuse
/// @notice Fuse for calculating the balance of assets in Silo V2 protocol
/// @dev This fuse calculates the total balance of assets held in Silo V2 markets by the PlasmaVault,
///      accounting for both positive balances (protected and collateral shares) and negative balances (debt shares).
///      Each SiloConfig (one isolated market made of two silos) is valued on its own: the signed value of its two
///      silos is floored at zero and only then added to the other markets, so the shortfall of one underwater market
///      is never charged to a healthy one and a negative net never reverts. Simplification: the vault's deposit in
///      the debt silo of the same market is netted inside the same SiloConfig unit (it is not counted in full
///      outside the market floor).
contract SiloV2BalanceFuse is IMarketBalanceFuse {
    using SafeCast for int256;

    /// @dev The version of the contract.
    address public immutable VERSION;
    /// @dev The unique identifier for IporFusionMarkets.
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function balanceOf() external view override returns (uint256 balance) {
        bytes32[] memory siloConfigs = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = siloConfigs.length;

        if (len == 0) {
            return 0;
        }

        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();
        address plasmaVault = address(this);

        uint256 totalBalance;

        for (uint256 i; i < len; ++i) {
            address siloConfig = PlasmaVaultConfigLib.bytes32ToAddress(siloConfigs[i]);
            (address silo0, address silo1) = ISiloConfig(siloConfig).getSilos();

            /// @dev Floor each isolated market (SiloConfig) at zero before summing the markets
            int256 marketBalance = _calculateSiloBalance(plasmaVault, siloConfig, silo0, priceOracleMiddleware) +
                _calculateSiloBalance(plasmaVault, siloConfig, silo1, priceOracleMiddleware);

            if (marketBalance > 0) {
                totalBalance += marketBalance.toUint256();
            }
        }

        balance = totalBalance;
    }

    function _calculateSiloBalance(
        address plasmaVault_,
        address siloConfig_,
        address silo_,
        address priceOracleMiddleware_
    ) internal view returns (int256 siloBalance) {
        address siloAssetAddress = ISilo(silo_).asset();

        (uint256 siloAssetPrice, uint256 siloAssetPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware_)
            .getAssetPrice(siloAssetAddress);

        int256 siloAssets = _getSiloAssets(plasmaVault_, siloConfig_, silo_);

        if (siloAssets == 0) {
            return 0;
        }

        if (siloAssets < 0) {
            // For negative silo assets, we need to handle the conversion carefully
            uint256 absSiloAssets = uint256(-siloAssets);
            uint256 convertedValue = IporMath.convertToWad(
                absSiloAssets * siloAssetPrice,
                IERC20Metadata(siloAssetAddress).decimals() + siloAssetPriceDecimals
            );
            return -int256(convertedValue);
        } else {
            return
                int256(
                    IporMath.convertToWad(
                        uint256(siloAssets) * siloAssetPrice,
                        IERC20Metadata(siloAssetAddress).decimals() + siloAssetPriceDecimals
                    )
                );
        }
    }

    function _getSiloAssets(
        address plasmaVault_,
        address siloConfig_,
        address silo_
    ) internal view returns (int256 siloAssets) {
        /// @dev Every share token has their own shares, we have to convert them to given Silo assets
        (address protectedShareToken, address collateralShareToken, address debtShareToken) = ISiloConfig(siloConfig_)
            .getShareTokens(silo_);

        uint256 grossAssets = ISilo(silo_).convertToAssets(
            IShareToken(protectedShareToken).balanceOf(plasmaVault_),
            ISilo.AssetType.Protected
        ) +
            ISilo(silo_).convertToAssets(
                IShareToken(collateralShareToken).balanceOf(plasmaVault_),
                ISilo.AssetType.Collateral
            );

        /// @dev Notice! Debt subtracts from the balance
        uint256 debtAssets = ISilo(silo_).convertToAssets(
            IShareToken(debtShareToken).balanceOf(plasmaVault_),
            ISilo.AssetType.Debt
        );

        siloAssets = int256(grossAssets) - int256(debtAssets);
    }
}

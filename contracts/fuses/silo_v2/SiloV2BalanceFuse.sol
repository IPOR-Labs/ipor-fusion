// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

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
import {SiloIndex} from "./SiloIndex.sol";

contract SiloV2BalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;

    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
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

        for (uint256 i; i < len; ++i) {
            address siloConfig = PlasmaVaultConfigLib.bytes32ToAddress(siloConfigs[i]);
            (address silo0, address silo1) = ISiloConfig(siloConfig).getSilos();

            balance += _calculateSiloBalance(plasmaVault, siloConfig, silo0, priceOracleMiddleware);
            balance += _calculateSiloBalance(plasmaVault, siloConfig, silo1, priceOracleMiddleware);
        }

        return balance;
    }

    function _calculateSiloBalance(
        address plasmaVault_,
        address siloConfig_,
        address silo_,
        address priceOracleMiddleware_
    ) internal view returns (uint256 siloBalance) {
        address siloAssetAddress = ISilo(silo_).asset();

        (uint256 siloAssetPrice, uint256 siloAssetPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware_)
            .getAssetPrice(siloAssetAddress);

        uint256 siloAssets = _getSiloAssets(plasmaVault_, siloConfig_, silo_);

        if (siloAssets == 0) {
            return 0;
        }

        return
            IporMath.convertToWad(
                siloAssets * siloAssetPrice,
                IERC20Metadata(siloAssetAddress).decimals() + siloAssetPriceDecimals
            );
    }

    function _getSiloAssets(
        address plasmaVault_,
        address siloConfig_,
        address silo_
    ) internal view returns (uint256 siloAssets) {
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
        uint256 debtAssets = ISilo(silo_).convertToAssets(IShareToken(debtShareToken).balanceOf(plasmaVault_), ISilo.AssetType.Debt);

        siloAssets = grossAssets > debtAssets ? grossAssets - debtAssets : 0;
    
    }
}

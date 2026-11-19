// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {
    EbisuZapperSubstrateLib,
    EbisuZapperSubstrate,
    EbisuZapperSubstrateType
} from "./lib/EbisuZapperSubstrateLib.sol";
import {ILeverageZapper} from "./ext/ILeverageZapper.sol";
import {ITroveManager} from "./ext/ITroveManager.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";

/**
 * @title Fuse for Ebisu protocol responsible for calculating the balance of the Plasma Vault in Ebisu protocol based on preconfigured market substrates
 * @dev Substrates in this fuse are the address registries of Ebisu protocol that are used in the Ebisu protocol for a given MARKET_ID
 */
contract EbisuZapperBalanceFuse is IMarketBalanceFuse {
    /// @notice Thrown when market ID is zero
    /// @custom:error EbisuZapperBalanceFuseInvalidMarketId
    error EbisuZapperBalanceFuseInvalidMarketId();

    uint256 public immutable MARKET_ID;

    /**
     * @notice Initializes the EbisuZapperBalanceFuse with a specific market ID
     * @param marketId_ The market ID used to identify the Ebisu protocol market substrates
     * @dev Reverts if marketId_ is zero
     */
    constructor(uint256 marketId_) {
        if (marketId_ == 0) {
            revert EbisuZapperBalanceFuseInvalidMarketId();
        }
        MARKET_ID = marketId_;
    }

    /**
     * @notice Calculates the total balance of the Plasma Vault in Ebisu protocol based on configured zapper and registry substrates
     * @dev The value contained in an open Trove is collateral - debt (each with its own price).
     *      Since interest fees automatically increase the entireDebt of the trove, we do not need to include it explicitly.
     *      This function iterates through all configured substrates, filters for ZAPPER type substrates,
     *      retrieves trove data for each zapper, calculates the total collateral and debt values,
     *      and returns the sum of the net values of the troves, each floored at zero on its own
     *      (an underwater trove contributes 0 and does not reduce the value of the healthy ones).
     *      For every REGISTRY substrate the collateral surplus that liquidations credited to the vault in the
     *      branch's CollSurplusPool (not yet claimed with EbisuClaimCollateralFuse) is added to the total, outside the
     *      per-trove floor.
     * @return The total balance of the vault in Ebisu protocol, calculated as the sum of max(0, collateral - debt)
     *         per trove across all configured zapper substrates, plus the valued collateral surplus
     *         of all configured registry substrates
     */
    function balanceOf() external view returns (uint256) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        FuseStorageLib.EbisuTroveIds storage troveData = FuseStorageLib.getEbisuTroveIds();

        uint256 substratesNumber = substrates.length;

        if (substratesNumber == 0) return 0;
        address ebusdAddress;
        uint256 ebusdPrice;
        uint256 ebusdPriceDecimals;
        uint256 totalValue;
        IPriceOracleMiddleware priceOracleMiddleware = IPriceOracleMiddleware(
            PlasmaVaultLib.getPriceOracleMiddleware()
        );
        uint256 troveId;
        EbisuZapperSubstrate memory target;

        for (uint256 i; i < substratesNumber; ++i) {
            target = EbisuZapperSubstrateLib.bytes32ToSubstrate(substrates[i]);

            if (target.substrateType == EbisuZapperSubstrateType.REGISTRY) {
                totalValue += _collSurplusValue(target.substrateAddress, priceOracleMiddleware);
                continue;
            }

            if (target.substrateType != EbisuZapperSubstrateType.ZAPPER) continue;

            if (ebusdAddress == address(0)) {
                /// @dev bold token (ebUSD) is the same for all zappers
                ebusdAddress = ILeverageZapper(target.substrateAddress).boldToken();
                (ebusdPrice, ebusdPriceDecimals) = priceOracleMiddleware.getAssetPrice(ebusdAddress);
            }

            troveId = troveData.troveIds[target.substrateAddress];
            if (troveId == 0) continue;

            totalValue += _troveValue(
                target.substrateAddress,
                troveId,
                priceOracleMiddleware,
                ebusdAddress,
                ebusdPrice,
                ebusdPriceDecimals
            );
        }

        return totalValue;
    }

    /// @dev Net value (WAD) of one trove, floored at zero on its own: max(coll - debt, 0). Every trove is liquidated
    ///      independently, so the shortfall of an underwater trove must not reduce the value of the healthy ones.
    function _troveValue(
        address zapper_,
        uint256 troveId_,
        IPriceOracleMiddleware priceOracleMiddleware_,
        address ebusdAddress_,
        uint256 ebusdPrice_,
        uint256 ebusdPriceDecimals_
    ) private view returns (uint256) {
        /// @dev At this point, we expect the contract to have collToken and troveManager
        address collToken = ILeverageZapper(zapper_).collToken();
        (uint256 collTokenPrice, uint256 collTokenPriceDecimals) = priceOracleMiddleware_.getAssetPrice(collToken);

        ITroveManager.LatestTroveData memory latestTroveData = ITroveManager(ILeverageZapper(zapper_).troveManager())
            .getLatestTroveData(troveId_);

        uint256 collValue = IporMath.convertToWad(
            latestTroveData.entireColl * collTokenPrice,
            IERC20Metadata(collToken).decimals() + collTokenPriceDecimals
        );
        uint256 debtValue = IporMath.convertToWad(
            latestTroveData.entireDebt * ebusdPrice_,
            IERC20Metadata(ebusdAddress_).decimals() + ebusdPriceDecimals_
        );

        return collValue - IporMath.min(debtValue, collValue);
    }

    /// @dev Value (WAD) of the collateral surplus the vault has in the CollSurplusPool of the branch; the collateral
    ///      price is only requested when there is a surplus, so branches without one never depend on the price feed.
    function _collSurplusValue(
        address registry_,
        IPriceOracleMiddleware priceOracleMiddleware_
    ) private view returns (uint256) {
        uint256 surplus = IAddressesRegistry(registry_).collSurplusPool().getCollateral(address(this));
        if (surplus == 0) return 0;

        address collToken = address(IAddressesRegistry(registry_).collToken());
        (uint256 price, uint256 priceDecimals) = priceOracleMiddleware_.getAssetPrice(collToken);
        return IporMath.convertToWad(surplus * price, IERC20Metadata(collToken).decimals() + priceDecimals);
    }
}

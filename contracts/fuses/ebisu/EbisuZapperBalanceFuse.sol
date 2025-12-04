// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {EbisuZapperSubstrateLib, EbisuZapperSubstrate, EbisuZapperSubstrateType} from "./lib/EbisuZapperSubstrateLib.sol";
import {ILeverageZapper} from "./ext/ILeverageZapper.sol";
import {ITroveManager} from "./ext/ITroveManager.sol";

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
     * @notice Calculates the total balance of the Plasma Vault in Ebisu protocol based on configured zapper substrates
     * @dev The value contained in an open Trove is collateral - debt (each with its own price).
     *      Since interest fees automatically increase the entireDebt of the trove, we do not need to include it explicitly.
     *      This function iterates through all configured substrates, filters for ZAPPER type substrates,
     *      retrieves trove data for each zapper, calculates the total collateral and debt values,
     *      and returns the net value (collateral - debt, minimum 0).
     * @return The total balance of the vault in Ebisu protocol, calculated as the sum of all trove values
     *         (collateral - debt) across all configured zapper substrates
     */
    function balanceOf() external view returns (uint256) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        FuseStorageLib.EbisuTroveIds storage troveData = FuseStorageLib.getEbisuTroveIds();

        uint256 substratesNumber = substrates.length;

        if (substratesNumber == 0) return 0;
        address collToken;
        uint256 collTokenPrice;
        uint256 collTokenPriceDecimals;
        address ebusdAddress;
        uint256 ebusdPrice;
        uint256 ebusdPriceDecimals;
        uint256 entireCollValue;
        uint256 entireDebtValue;
        IPriceOracleMiddleware priceOracleMiddleware = IPriceOracleMiddleware(
            PlasmaVaultLib.getPriceOracleMiddleware()
        );
        uint256 troveId;
        EbisuZapperSubstrate memory target;

        for (uint256 i; i < substratesNumber; ++i) {
            target = EbisuZapperSubstrateLib.bytes32ToSubstrate(substrates[i]);

            if (target.substrateType != EbisuZapperSubstrateType.ZAPPER) continue;

            if (ebusdAddress == address(0)) {
                /// @dev bold token (ebUSD) is the same for all zappers
                ebusdAddress = ILeverageZapper(target.substrateAddress).boldToken();
                (ebusdPrice, ebusdPriceDecimals) = priceOracleMiddleware.getAssetPrice(ebusdAddress);
            }

            troveId = troveData.troveIds[target.substrateAddress];
            if (troveId == 0) continue;
            /// @dev At this point, we expect the contract to have collToken and troveManager
            collToken = ILeverageZapper(target.substrateAddress).collToken();
            (collTokenPrice, collTokenPriceDecimals) = priceOracleMiddleware.getAssetPrice(collToken);

            ITroveManager.LatestTroveData memory latestTroveData = ITroveManager(
                ILeverageZapper(target.substrateAddress).troveManager()
            ).getLatestTroveData(troveId);

            entireCollValue += IporMath.convertToWad(
                latestTroveData.entireColl * collTokenPrice,
                IERC20Metadata(collToken).decimals() + collTokenPriceDecimals
            );

            entireDebtValue += IporMath.convertToWad(
                latestTroveData.entireDebt * ebusdPrice,
                IERC20Metadata(ebusdAddress).decimals() + ebusdPriceDecimals
            );
        }

        /// @dev max(coll - debt, 0)
        return entireCollValue - IporMath.min(entireDebtValue, entireCollValue);
    }
}

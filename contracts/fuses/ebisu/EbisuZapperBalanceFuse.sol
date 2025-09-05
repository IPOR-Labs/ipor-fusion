// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {EbisuMathLibrary} from "./EbisuMathLibrary.sol";
import {ITroveManager} from "./ext/ITroveManager.sol";
import {ILeverageZapper} from "./ext/ILeverageZapper.sol";

/**
 * @title Fuse for Ebisu protocol responsible for calculating the balance of the Plasma Vault in Ebisu protocol based on preconfigured market substrates
 * @dev Substrates in this fuse are the address registries of Ebisu protocol that are used in the Ebisu protocol for a given MARKET_ID
 */
contract EbisuZapperBalanceFuse is IMarketBalanceFuse {
    using SafeCast for int256;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId) {
        MARKET_ID = marketId;
    }

    function balanceOf() external view returns (uint256) {
        bytes32[] memory zappersRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        FuseStorageLib.EbisuOwnerIds storage troveData = FuseStorageLib.getEbisuOwnerIds();

        uint256 zappersNumber = zappersRaw.length;

        if (zappersNumber == 0) return 0;
        address collToken;
        uint256 collTokenPrice;
        uint256 collTokenPriceDecimals;
        uint256 entireCollValue;
        IPriceOracleMiddleware priceOracleMiddleware = IPriceOracleMiddleware(
            PlasmaVaultLib.getPriceOracleMiddleware()
        );
        address zapper;
        ITroveManager troveManager;
        uint256 idsLen;
        uint256 troveId;

        for (uint256 i; i < zappersNumber; ++i) {
            zapper = PlasmaVaultConfigLib.bytes32ToAddress(zappersRaw[i]);
            troveManager = ITroveManager(ILeverageZapper(zapper).troveManager());
            collToken = ILeverageZapper(zapper).collToken();
            (collTokenPrice, collTokenPriceDecimals) = priceOracleMiddleware.getAssetPrice(collToken);
            idsLen = troveData.ownerIds[address(zapper)].length;

            for(uint256 j; j < idsLen; ++j) {
                troveId = EbisuMathLibrary.calculateTroveId(address(this), zapper, troveData.ownerIds[address(zapper)][j]);
                if (troveId == 0) continue;
                entireCollValue += IporMath.convertToWad(
                    troveManager.getLatestTroveData(troveId).entireColl * collTokenPrice,
                    IERC20Metadata(collToken).decimals() + collTokenPriceDecimals
                );
            }
        }
        return entireCollValue;
    }
}
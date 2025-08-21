// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IPriceFeed} from "./ext/IPriceFeed.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {EbisuFuseStorageLib} from "../../libraries/EbisuFuseStorageLib.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {ITroveManager} from "./ext/ITroveManager.sol";

/// @title Fuse for Ebisu protocol responsible for calculating the balance of the Plasma Vault in Ebisu protocol based on preconfigured market substrates
/// @dev Substrates in this fuse are the address registries of Ebisu protocol that are used in the Ebisu protocol for a given MARKET_ID
contract EbisuTroveBalanceFuse is IMarketBalanceFuse {
    using SafeCast for int256;
    uint256 public immutable MARKET_ID;

    uint256 private constant EBISU_ORACLE_BASE_CURRENCY_DECIMALS = 18;

    constructor(uint256 marketId) {
        MARKET_ID = marketId;
    }

    // The balance is composed of the value of the Plasma Vault in USD
    // The Plasma Vault can contain ebUSD (Ebisu's stablecoin) and stcUSD (Cap protocol's yield-bearing stablecoin)
    function balanceOf() external view override returns (uint256 balanceTemp) {
        bytes32[] memory registriesRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        EbisuFuseStorageLib.EbisuOwnerIds storage troveData = EbisuFuseStorageLib.getEbisuOwnerIds();

        uint256 registryNumber = registriesRaw.length;

        if (registryNumber == 0) return 0;
        address collToken;
        uint256 collTokenPrice;
        uint256 collTokenPriceDecimals;
        uint256 entireCollValue;
        IPriceOracleMiddleware priceOracleMiddleware = IPriceOracleMiddleware(
            PlasmaVaultLib.getPriceOracleMiddleware()
        );
        for (uint256 i; i < registryNumber; ++i) {
            address registry = PlasmaVaultConfigLib.bytes32ToAddress(registriesRaw[i]);
            ITroveManager troveManager = ITroveManager(IAddressesRegistry(registry).troveManager());
            collToken = IAddressesRegistry(registry).collToken();
            (collTokenPrice, collTokenPriceDecimals) = priceOracleMiddleware.getAssetPrice(collToken);
            uint256 idsLen = troveData.troveIds[registry].length;

            for(uint256 j; j < idsLen; ++j) {
                uint256 troveId = troveData.troveIds[registry][j];
                if (troveId == 0) continue;
                entireCollValue += IporMath.convertToWad(
                    troveManager.getLatestTroveData(troveId).entireColl * collTokenPrice,
                    IERC20Metadata(collToken).decimals() + collTokenPriceDecimals
                );
                // TODO: investigate with IPOR team or Liquity if we need to add interests here
            }
        }

        return entireCollValue;
    }
}
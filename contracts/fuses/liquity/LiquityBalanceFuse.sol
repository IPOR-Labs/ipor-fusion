// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IStabilityPool} from "./ext/IStabilityPool.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";
import {IporFusionMarkets} from "../../libraries/IporFusionMarkets.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

/// @title Fuse for Liquity protocol responsible for calculating the balance of the Plasma Vault in Liquity protocol based on preconfigured market substrates
/// @dev Substrates in this fuse are the address registries of Liquity protocol that are used in the Liquity protocol for a given MARKET_ID
contract LiquityBalanceFuse is IMarketBalanceFuse {
    using SafeCast for int256;
    uint256 public immutable MARKET_ID;

    uint256 private constant LIQUITY_ORACLE_BASE_CURRENCY_DECIMALS = 18;

    error InvalidMarketId();
    error InvalidRegistry();

    constructor(uint256 marketId) {
        if (marketId != IporFusionMarkets.LIQUITY_V2) revert InvalidMarketId();

        MARKET_ID = marketId;
    }

    // The balance is composed of the value of the Plasma Vault in USD
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory registriesRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = registriesRaw.length;

        if (len == 0) return 0;

        uint256 collBalance;
        uint256 totalDeposits;
        uint256 tokenPrice;
        IAddressesRegistry registry;
        IStabilityPool stabilityPool;
        uint256 stashedCollateral;
        address collToken;
        uint256 tokenDecimals;

        IPriceOracleMiddleware priceOracleMiddleware = IPriceOracleMiddleware(
            PlasmaVaultLib.getPriceOracleMiddleware()
        );
        registry = IAddressesRegistry(PlasmaVaultConfigLib.bytes32ToAddress(registriesRaw[0]));

        (uint256 boldPrice, uint256 boldDecimals) = priceOracleMiddleware.getAssetPrice(registry.boldToken());

        // loop through all registries to calculate stashed collateral and deposits
        for (uint256 i; i < len; ++i) {
            if (i > 0) registry = IAddressesRegistry(PlasmaVaultConfigLib.bytes32ToAddress(registriesRaw[i]));

            stabilityPool = IStabilityPool(registry.stabilityPool());
            collToken = registry.collToken();

            (tokenPrice, tokenDecimals) = priceOracleMiddleware.getAssetPrice(collToken);

            // The stashed collateral in the stability pool, i.e. not yet claimed
            // They are denominated in the collateral token, so we need to convert them to USD
            stashedCollateral = stabilityPool.stashedColl(address(this));
            if (stashedCollateral > 0) {
                collBalance += IporMath.convertToWad(
                    stashedCollateral * tokenPrice,
                    tokenDecimals + LIQUITY_ORACLE_BASE_CURRENCY_DECIMALS
                );
            }

            totalDeposits += IporMath.convertToWad(
                stabilityPool.deposits(address(this)) * boldPrice,
                boldDecimals + LIQUITY_ORACLE_BASE_CURRENCY_DECIMALS
            );
        }

        return collBalance + totalDeposits;
    }
}

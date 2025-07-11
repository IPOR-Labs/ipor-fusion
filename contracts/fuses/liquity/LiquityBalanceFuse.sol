// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IStabilityPool} from "./ext/IStabilityPool.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";
import {IporFusionMarkets} from "../../libraries/IporFusionMarkets.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

/**
 * @title Fuse for Liquity protocol responsible for calculating the balance of the Plasma Vault in Liquity protocol based on preconfigured market substrates
 * @dev Substrates in this fuse are the address registries of Liquity protocol that are used in the Liquity protocol for a given MARKET_ID
 */
contract LiquityBalanceFuse is IMarketBalanceFuse {
    uint256 public immutable MARKET_ID;

    error InvalidMarketId();

    constructor(uint256 marketId) {
        MARKET_ID = marketId;
    }

    /**
     * @dev Calculates the USD-denominated balance of the Plasma Vault in the Liquity protocol.
     *      The balance includes BOLD token deposits and unclaimed collateral gains across all configured registries.
     *      It is assumed that BOLD token is the same across all registries
     * @return The total balance of the Plasma Vault in USD (scaled to 18 decimals, that are the BOLD decimals).
     */
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory registriesRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        uint256 len = registriesRaw.length;
        if (len == 0) return 0;

        IStabilityPool stabilityPool;
        uint256 totalDeposits;
        uint256 totalCollateral;
        address collToken;
        uint256 collTokenPrice;
        uint256 collTokenPriceDecimals;

        IPriceOracleMiddleware priceOracleMiddleware = IPriceOracleMiddleware(
            PlasmaVaultLib.getPriceOracleMiddleware()
        );
        IAddressesRegistry registry = IAddressesRegistry(PlasmaVaultConfigLib.bytes32ToAddress(registriesRaw[0]));
        address boldToken = registry.boldToken();
        (uint256 boldPrice, uint256 boldPriceDecimals) = priceOracleMiddleware.getAssetPrice(boldToken);
        uint256 boldDecimals = IERC20Metadata(boldToken).decimals();

        for (uint256 i; i < len; ++i) {
            if (i > 0) registry = IAddressesRegistry(PlasmaVaultConfigLib.bytes32ToAddress(registriesRaw[i]));

            stabilityPool = IStabilityPool(registry.stabilityPool());
            collToken = registry.collToken();

            (collTokenPrice, collTokenPriceDecimals) = priceOracleMiddleware.getAssetPrice(collToken);

            totalCollateral += IporMath.convertToWad(
                stabilityPool.stashedColl(address(this)) * collTokenPrice,
                IERC20Metadata(collToken).decimals() + collTokenPriceDecimals
            );

            totalDeposits += IporMath.convertToWad(
                stabilityPool.deposits(address(this)) * boldPrice,
                boldDecimals + boldPriceDecimals
            );
        }

        return totalCollateral + totalDeposits;
    }
}

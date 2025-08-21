// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IStabilityPool} from "./ext/IStabilityPool.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

/**
 * @title Fuse for Ebisu protocol responsible for calculating the balance of the Plasma Vault in Ebisu protocol based on preconfigured market substrates
 * @dev Substrates in this fuse are the address registries of Ebisu protocol that are used in the Ebisu protocol for a given MARKET_ID
 */
contract EbisuBalanceFuse is IMarketBalanceFuse {
    uint256 public immutable MARKET_ID;

    error InvalidMarketId();

    constructor(uint256 marketId) {
        MARKET_ID = marketId;
    }

    /**
     * @dev Calculates the USD-denominated balance of the Plasma Vault in the Ebisu protocol.
     *      The balance includes BOLD token deposits and unclaimed collateral gains across all configured registries.
     *      It is assumed that BOLD token is the same across all registries
     * @return The total balance of the Plasma Vault in USD (scaled to 18 decimals, that are the BOLD decimals).
     */
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory registriesRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        uint256 len = registriesRaw.length;
        if (len == 0) return 0;

        IStabilityPool stabilityPool;
        IAddressesRegistry registry;
        address boldToken;
        uint256 boldPrice;
        uint256 boldPriceDecimals;
        uint256 boldDecimals;
        uint256 totalDeposits;
        uint256 totalCollateral;
        address collToken;
        uint256 collTokenPrice;
        uint256 collTokenPriceDecimals;

        IPriceOracleMiddleware priceOracleMiddleware = IPriceOracleMiddleware(
            PlasmaVaultLib.getPriceOracleMiddleware()
        );

        for (uint256 i; i < len; ++i) {
            registry = IAddressesRegistry(PlasmaVaultConfigLib.bytes32ToAddress(registriesRaw[i]));
            if (i == 0) {
                boldToken = registry.boldToken();
                (boldPrice, boldPriceDecimals) = priceOracleMiddleware.getAssetPrice(boldToken);
                boldDecimals = IERC20Metadata(boldToken).decimals();
            }

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

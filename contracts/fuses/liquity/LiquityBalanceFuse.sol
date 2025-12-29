// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IStabilityPool} from "./ext/IStabilityPool.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

/**
 * @title Fuse for Liquity protocol responsible for calculating the balance of the Plasma Vault in Liquity protocol based on preconfigured market substrates
 * @dev Substrates in this fuse are the address registries of Liquity protocol that are used in the Liquity protocol for a given MARKET_ID
 */
contract LiquityBalanceFuse is IMarketBalanceFuse {
    uint256 public immutable MARKET_ID;

    /// @notice Thrown when market ID is zero
    /// @custom:error LiquityBalanceFuseInvalidMarketId
    error LiquityBalanceFuseInvalidMarketId();

    /// @notice Constructor to initialize the fuse with a market ID
    /// @param marketId_ The unique identifier for the market configuration
    /// @dev The market ID is used to retrieve the list of substrates (address registries) that this fuse will track.
    ///      Reverts if marketId_ is zero.
    constructor(uint256 marketId_) {
        if (marketId_ == 0) {
            revert LiquityBalanceFuseInvalidMarketId();
        }
        MARKET_ID = marketId_;
    }

    /**
     * @notice Calculates the USD-denominated balance of the Plasma Vault in the Liquity protocol.
     *         The balance includes:
     *         - Current BOLD deposits (compounded after liquidations)
     *         - Stashed collateral (claimed but not sent)
     *         - Unrealized collateral gains from liquidations
     *         - Unrealized BOLD yield gains from interest
     *         It is assumed that BOLD token is the same across all registries
     * @return The total balance of the Plasma Vault in USD (scaled to 18 decimals, that are the BOLD decimals).
     */
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory registriesRaw = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        uint256 len = registriesRaw.length;
        if (len == 0) return 0;

        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();
        address plasmaVault = address(this);
        uint256 totalBoldValue;
        uint256 totalCollateralValue;

        /// @dev Get BOLD token info from first registry (assumed same across all)
        IAddressesRegistry firstRegistry = IAddressesRegistry(PlasmaVaultConfigLib.bytes32ToAddress(registriesRaw[0]));
        address boldToken = firstRegistry.boldToken();
        (uint256 boldPrice, uint256 boldPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware).getAssetPrice(
            boldToken
        );
        uint256 boldDecimals = IERC20Metadata(boldToken).decimals();
        IAddressesRegistry registry;
        IStabilityPool stabilityPool;

        for (uint256 i; i < len; ++i) {
            registry = IAddressesRegistry(PlasmaVaultConfigLib.bytes32ToAddress(registriesRaw[i]));
            stabilityPool = IStabilityPool(registry.stabilityPool());

            /// @dev Calculate collateral value for this registry
            totalCollateralValue += _calculateCollateralValue(
                stabilityPool,
                registry.collToken(),
                plasmaVault,
                priceOracleMiddleware
            );

            /// @dev Calculate BOLD value for this registry
            totalBoldValue += _calculateBoldValue(
                stabilityPool,
                plasmaVault,
                boldPrice,
                boldDecimals,
                boldPriceDecimals
            );
        }

        return totalCollateralValue + totalBoldValue;
    }

    /**
     * @notice Calculates the total collateral value (stashed + unrealized gains) for a single registry
     * @param stabilityPool_ The stability pool contract interface
     * @param collToken_ The address of the collateral token
     * @param plasmaVault_ The address of the Plasma Vault
     * @param priceOracleMiddleware_ The address of the price oracle middleware
     * @return The total collateral value in USD (scaled to 18 decimals)
     * @dev Calculates both stashed collateral (claimed but not sent) and unrealized collateral gains from liquidations
     */
    function _calculateCollateralValue(
        IStabilityPool stabilityPool_,
        address collToken_,
        address plasmaVault_,
        address priceOracleMiddleware_
    ) private view returns (uint256) {
        (uint256 collTokenPrice, uint256 collTokenPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware_)
            .getAssetPrice(collToken_);
        uint256 collTokenDecimals = IERC20Metadata(collToken_).decimals();
        uint256 decimalsSum = collTokenDecimals + collTokenPriceDecimals;

        uint256 stashedValue = IporMath.convertToWad(
            stabilityPool_.stashedColl(plasmaVault_) * collTokenPrice,
            decimalsSum
        );

        uint256 unrealizedGainValue = IporMath.convertToWad(
            stabilityPool_.getDepositorCollGain(plasmaVault_) * collTokenPrice,
            decimalsSum
        );

        return stashedValue + unrealizedGainValue;
    }

    /**
     * @notice Calculates the total BOLD value (compounded deposits + unrealized yield gains) for a single registry
     * @param stabilityPool_ The stability pool contract interface
     * @param plasmaVault_ The address of the Plasma Vault
     * @param boldPrice_ The price of BOLD token (from price oracle)
     * @param boldDecimals_ The number of decimals for BOLD token
     * @param boldPriceDecimals_ The number of decimals for BOLD price from oracle
     * @return The total BOLD value in USD (scaled to 18 decimals)
     * @dev Calculates both compounded BOLD deposits and unrealized yield gains from interest
     */
    function _calculateBoldValue(
        IStabilityPool stabilityPool_,
        address plasmaVault_,
        uint256 boldPrice_,
        uint256 boldDecimals_,
        uint256 boldPriceDecimals_
    ) private view returns (uint256) {
        uint256 decimalsSum = boldDecimals_ + boldPriceDecimals_;

        uint256 depositValue = IporMath.convertToWad(
            stabilityPool_.getCompoundedBoldDeposit(plasmaVault_) * boldPrice_,
            decimalsSum
        );

        uint256 yieldGainValue = IporMath.convertToWad(
            stabilityPool_.getDepositorYieldGainWithPending(plasmaVault_) * boldPrice_,
            decimalsSum
        );

        return depositValue + yieldGainValue;
    }
}

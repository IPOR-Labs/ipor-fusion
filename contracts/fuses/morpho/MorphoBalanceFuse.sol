// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";

import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {Errors} from "../../libraries/errors/Errors.sol";

import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {MorphoStorageLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoStorageLib.sol";
import {SharesMathLib} from "@morpho-org/morpho-blue/src/libraries/SharesMathLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

/**
 * @title Fuse for calculating Morpho protocol balance in Plasma Vault
 * @notice Calculates the total balance of the Plasma Vault in Morpho protocol as the sum of its Morpho Blue markets,
 *         each market valued on its own by what the vault keeps once its debt is settled, never below zero
 * @dev Substrates in this fuse are the Morpho Market IDs (bytes32) that are configured for a given MARKET_ID.
 *      This fuse iterates through all configured Morpho markets, calculates:
 *      - Collateral value from collateral tokens
 *      - Net supply position (supply - borrow) for loan tokens
 *      Converts all values to USD using price oracle middleware and returns the sum normalized to WAD (18 decimals).
 *
 *      Per-market floor (IL-9528, D-014): Morpho Blue markets are isolated, a liquidation seizes only the collateral
 *      of the position in that market and the bad debt it leaves is written off against the lenders of that market.
 *      The liability of the vault is therefore limited per market, so an underwater market (collateral below debt)
 *      is never valued below zero and its shortfall is not charged: it neither lowers the value of the other markets
 *      nor makes the sum negative, which used to revert every call refreshing this market (SafeCast of a negative
 *      total). The function does not revert for an underwater market and does not police the position.
 *
 *      Mixed market: plain supply of the loan token in a market in which the vault also borrows is never seized and
 *      a borrow does not lock it. While the market is underwater the supply counts in full, minus the vault's part of
 *      the debt that Morpho will write off against the lenders of the market (bounded by the whole debt), so the
 *      value is never above what the vault keeps and a liquidation steps it up by at most the vault's part of the
 *      repaid debt (`_marketValue`).
 */
contract MorphoBalanceFuse is IMarketBalanceFuse {
    using MorphoBalancesLib for IMorpho;
    using SharesMathLib for uint256;

    /// @notice Address of this fuse contract version
    /// @dev Immutable value set in constructor, used for tracking and versioning
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    /// @dev Immutable value set in constructor, used to retrieve market substrates (Morpho Market IDs)
    uint256 public immutable MARKET_ID;

    /// @notice Morpho protocol contract address
    /// @dev Immutable value set in constructor, used for Morpho protocol interactions
    IMorpho public immutable MORPHO;

    /**
     * @notice Initializes the MorphoBalanceFuse with a market ID and Morpho address
     * @param marketId_ The market ID used to identify the Morpho market substrates
     * @param morpho_ The address of the Morpho protocol contract (must not be address(0))
     * @dev Reverts if marketId_ is zero or morpho_ is zero address
     */
    constructor(uint256 marketId_, address morpho_) {
        if (marketId_ == 0) {
            revert Errors.WrongValue();
        }
        if (morpho_ == address(0)) {
            revert Errors.WrongAddress();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        MORPHO = IMorpho(morpho_);
    }

    /**
     * @notice Calculates the total net balance of the Plasma Vault in Morpho protocol
     * @dev This function:
     *      1. Retrieves all substrates (Morpho Market IDs) configured for the market
     *      2. For each market, retrieves market parameters and calculates:
     *         - Collateral assets value (from collateral tokens)
     *         - Supply assets (expected supply position)
     *         - Borrow assets (expected borrow position)
     *      3. Converts all asset values to USD using price oracle middleware
     *      4. Values each market on its own (`_marketValue`, never below zero) and sums the markets, returning the
     *         total normalized to WAD (18 decimals)
     *      The function uses Morpho's expectedSupplyAssets and expectedBorrowAssets for accurate position calculations.
     * @return The total net balance of the Plasma Vault in Morpho protocol in USD, normalized to WAD (18 decimals)
     */
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory morphoMarkets = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = morphoMarkets.length;
        if (len == 0) {
            return 0;
        }

        uint256 balance;
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        for (uint256 i; i < len; ++i) {
            balance += _marketValue(Id.wrap(morphoMarkets[i]), address(this), priceOracleMiddleware);
        }

        return balance;
    }

    /**
     * @notice Value of the Plasma Vault's position in one Morpho Blue market, in USD normalized to WAD, never negative
     * @dev Collateral covers the debt: collateral + supply - borrow (supply - borrow converted once).
     *      Underwater (IL-9528): a liquidation seizes only the collateral and Morpho writes the rest of the debt off
     *      against the suppliers of this market, the vault among them. The supply is never seized and a borrow does
     *      not lock it, so it counts in full, minus the vault's part of the written-off debt, bounded by the whole
     *      debt (a liquidator repays at least zero). The value is never above what the vault keeps after the
     *      liquidation, and the liquidation steps it up by at most the vault's part of the repaid debt.
     */
    function _marketValue(
        Id marketId_,
        address plasmaVault_,
        address priceOracleMiddleware_
    ) private view returns (uint256) {
        MarketParams memory marketParams = MORPHO.idToMarketParams(marketId_);
        uint256 totalSupplyAssets = MORPHO.expectedSupplyAssets(marketParams, plasmaVault_);

        bytes32[] memory slots = new bytes32[](1);
        slots[0] = MorphoStorageLib.positionBorrowSharesAndCollateralSlot(marketId_, plasmaVault_);
        uint256 totalCollateralAssets = uint256(MORPHO.extSloads(slots)[0] >> 128);

        uint256 totalBorrowAssets = MORPHO.expectedBorrowAssets(marketParams, plasmaVault_);

        uint256 collateralValue = _convertToUsd(
            priceOracleMiddleware_,
            marketParams.collateralToken,
            totalCollateralAssets
        );
        uint256 borrowValue = _convertToUsd(priceOracleMiddleware_, marketParams.loanToken, totalBorrowAssets);

        if (collateralValue >= borrowValue) {
            if (totalSupplyAssets >= totalBorrowAssets) {
                return
                    collateralValue +
                    _convertToUsd(
                        priceOracleMiddleware_,
                        marketParams.loanToken,
                        totalSupplyAssets - totalBorrowAssets
                    );
            }

            uint256 netBorrowValue = _convertToUsd(
                priceOracleMiddleware_,
                marketParams.loanToken,
                totalBorrowAssets - totalSupplyAssets
            );

            return collateralValue > netBorrowValue ? collateralValue - netBorrowValue : 0;
        }

        if (totalSupplyAssets == 0) {
            return 0;
        }

        uint256 supplyValue = _convertToUsd(priceOracleMiddleware_, marketParams.loanToken, totalSupplyAssets);
        (uint256 marketSupplyAssets, , , ) = MORPHO.expectedMarketBalances(marketParams);

        return
            supplyValue -
            Math.min(supplyValue, Math.mulDiv(supplyValue, totalBorrowAssets, marketSupplyAssets, Math.Rounding.Ceil));
    }

    /**
     * @notice Converts an asset amount to USD value normalized to WAD (18 decimals)
     * @param priceOracleMiddleware_ The address of the price oracle middleware
     * @param asset_ The address of the asset to convert
     * @param amount_ The amount of the asset to convert
     * @return The USD value of the asset amount, normalized to WAD (18 decimals)
     * @dev Returns zero if amount_ is zero. Uses price oracle middleware to get asset price
     *      and converts using IporMath.convertToWad() with combined decimals (asset decimals + price decimals)
     */
    function _convertToUsd(
        address priceOracleMiddleware_,
        address asset_,
        uint256 amount_
    ) internal view returns (uint256) {
        if (amount_ == 0) return 0;
        (uint256 price, uint256 decimals) = IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(asset_);

        return IporMath.convertToWad(amount_ * price, ERC20(asset_).decimals() + decimals);
    }
}

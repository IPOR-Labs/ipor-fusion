// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
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
 * @notice Calculates the total net balance (collateral + supply - borrow) of the Plasma Vault in Morpho protocol
 * @dev Substrates in this fuse are the Morpho Market IDs (bytes32) that are configured for a given MARKET_ID.
 *      This fuse iterates through all configured Morpho markets, calculates:
 *      - Collateral value from collateral tokens
 *      - Net supply position (supply - borrow) for loan tokens
 *      Converts all values to USD using price oracle middleware and returns the sum normalized to WAD (18 decimals).
 */
contract MorphoBalanceFuse is IMarketBalanceFuse {
    using SafeCast for uint256;
    using SafeCast for int256;
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
     *         - Net position: collateral + (supply - borrow) for loan tokens
     *      3. Converts all asset values to USD using price oracle middleware
     *      4. Sums all positions and returns the total normalized to WAD (18 decimals)
     *      The function uses Morpho's expectedSupplyAssets and expectedBorrowAssets for accurate position calculations.
     * @return The total net balance of the Plasma Vault in Morpho protocol in USD, normalized to WAD (18 decimals)
     */
    function balanceOf() external view override returns (uint256) {
        bytes32[] memory morphoMarkets = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);

        uint256 len = morphoMarkets.length;
        if (len == 0) {
            return 0;
        }

        int256 balance = 0;
        uint256 totalCollateralAssets;
        uint256 totalBorrowAssets;
        uint256 totalSupplyAssets;
        bytes32[] memory slots = new bytes32[](1);
        bytes32[] memory values;
        address plasmaVault = address(this);

        MarketParams memory marketParams;

        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        for (uint256 i; i < len; ++i) {
            marketParams = MORPHO.idToMarketParams(Id.wrap(morphoMarkets[i]));
            totalSupplyAssets = MORPHO.expectedSupplyAssets(marketParams, plasmaVault);

            slots[0] = MorphoStorageLib.positionBorrowSharesAndCollateralSlot(Id.wrap(morphoMarkets[i]), plasmaVault);
            values = MORPHO.extSloads(slots);
            totalCollateralAssets = uint256(values[0] >> 128);

            totalBorrowAssets = MORPHO.expectedBorrowAssets(marketParams, plasmaVault);

            balance += _convertToUsd(priceOracleMiddleware, marketParams.collateralToken, totalCollateralAssets)
                .toInt256();

            if (totalSupplyAssets > totalBorrowAssets) {
                balance += _convertToUsd(
                    priceOracleMiddleware,
                    marketParams.loanToken,
                    totalSupplyAssets - totalBorrowAssets
                ).toInt256();
            } else {
                balance -= _convertToUsd(
                    priceOracleMiddleware,
                    marketParams.loanToken,
                    totalBorrowAssets - totalSupplyAssets
                ).toInt256();
            }
        }
        return balance.toUint256();
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

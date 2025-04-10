// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {AccessManagedUpgradeable} from "../access/AccessManagedUpgradeable.sol";
import {ContextClient} from "../context/ContextClient.sol";
import {UniversalReader} from "../../universal_reader/UniversalReader.sol";
import {PriceOracleMiddlewareManagerLib} from "./PriceOracleMiddlewareManagerLib.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IPriceFeed} from "../../price_oracle/price_feed/IPriceFeed.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";

contract PriceOracleMiddlewareManager is AccessManagedUpgradeable, ContextClient, UniversalReader {
    using SafeCast for int256;

    /// @dev Quote currency address representing USD (Chainlink standard)
    /// @notice This is the standard Chainlink USD address used for price feeds
    address public constant QUOTE_CURRENCY = address(0x0000000000000000000000000000000000000348);

    /// @dev Number of decimals used for USD price representation
    /// @notice Every price returned by a specific price feed is converted to this decimals
    uint256 public constant QUOTE_CURRENCY_DECIMALS = 18;

    /// @notice Thrown when the price oracle middleware is invalid
    error InvalidPriceOracleMiddleware();

    /// @notice Thrown when the authority is invalid
    error InvalidAuthority();

    /// @notice Thrown when an asset price cannot be found or is invalid
    error UnsupportedAsset();

    /// @notice Thrown when a price feed returns an unexpected result (e.g., price <= 0)
    error UnexpectedPriceResult();

    /// @notice Thrown when an empty array is passed where it's not supported
    error EmptyArrayNotSupported();

    /// @notice Thrown when input arrays have mismatched lengths
    error ArrayLengthMismatch();

    constructor(address initialAuthority_, address priceOracleMiddleware_) initializer {
        if (initialAuthority_ == address(0)) {
            revert InvalidAuthority();
        }

        if (priceOracleMiddleware_ == address(0)) {
            revert InvalidPriceOracleMiddleware();
        }

        super.__AccessManaged_init_unchained(initialAuthority_);

        PriceOracleMiddlewareManagerLib.setPriceOracleMiddleware(priceOracleMiddleware_);
    }

    /// @notice Sets or updates price feed sources for multiple assets
    /// @param assets_ Array of asset addresses
    /// @param sources_ Array of corresponding price feed sources
    /// @dev Arrays must be equal length and non-empty
    /// @dev Only callable by authorized addresses (via restricted modifier)
    function setAssetsPriceSources(address[] calldata assets_, address[] calldata sources_) external restricted {
        uint256 assetsLength = assets_.length;
        uint256 sourcesLength = sources_.length;

        if (assetsLength == 0) {
            revert EmptyArrayNotSupported();
        }
        if (assetsLength != sourcesLength) {
            revert ArrayLengthMismatch();
        }

        for (uint256 i; i < assetsLength; ++i) {
            PriceOracleMiddlewareManagerLib.addAssetPriceSource(assets_[i], sources_[i]);
        }
    }

    /// @notice Removes price feed sources for multiple assets
    /// @param assets_ Array of asset addresses to remove sources for
    /// @dev Array must be non-empty
    /// @dev Only callable by authorized addresses (via restricted modifier)
    function removeAssetsPriceSources(address[] calldata assets_) external restricted {
        uint256 assetsLength = assets_.length;

        if (assetsLength == 0) {
            revert EmptyArrayNotSupported();
        }

        for (uint256 i; i < assetsLength; ++i) {
            PriceOracleMiddlewareManagerLib.removeAssetPriceSource(assets_[i]);
        }
    }

    function setPriceOracleMiddleware(address priceOracleMiddleware_) external restricted {
        PriceOracleMiddlewareManagerLib.setPriceOracleMiddleware(priceOracleMiddleware_);
    }

    function getPriceOracleMiddleware() external view returns (address) {
        return PriceOracleMiddlewareManagerLib.getPriceOracleMiddleware();
    }

    function getSourceOfAssetPrice(address asset_) external view returns (address) {
        return PriceOracleMiddlewareManagerLib.getSourceOfAssetPrice(asset_);
    }

    function getConfiguredAssets() external view returns (address[] memory) {
        return PriceOracleMiddlewareManagerLib.getConfiguredAssets();
    }

    /// @notice Gets the USD price for a single asset
    /// @param asset_ The address of the asset to price
    /// @return assetPrice The price in USD (with QUOTE_CURRENCY_DECIMALS decimals)
    /// @return decimals The number of decimals in the returned price (always QUOTE_CURRENCY_DECIMALS)
    function getAssetPrice(address asset_) external view returns (uint256 assetPrice, uint256 decimals) {
        (assetPrice, decimals) = _getAssetPrice(asset_);
    }

    /// @notice Gets USD prices for multiple assets in a single call
    /// @param assets_ Array of asset addresses to price
    /// @return assetPrices Array of prices in USD (with QUOTE_CURRENCY_DECIMALS decimals)
    /// @return decimalsList Array of decimals for each returned price (always QUOTE_CURRENCY_DECIMALS)
    /// @dev Reverts if:
    /// @dev - assets_ array is empty
    /// @dev - any asset price cannot be determined or is invalid
    function getAssetsPrices(
        address[] calldata assets_
    ) external view returns (uint256[] memory assetPrices, uint256[] memory decimalsList) {
        uint256 assetsLength = assets_.length;

        if (assetsLength == 0) {
            revert EmptyArrayNotSupported();
        }

        assetPrices = new uint256[](assetsLength);
        decimalsList = new uint256[](assetsLength);

        for (uint256 i; i < assetsLength; ++i) {
            (assetPrices[i], decimalsList[i]) = _getAssetPrice(assets_[i]);
        }
    }

    /// @notice Internal function to get asset price from either custom source or PriceOracleMiddleware
    /// @param asset_ The address of the asset to price
    /// @return assetPrice The price in USD (with QUOTE_CURRENCY_DECIMALS decimals)
    /// @return decimals The number of decimals in the returned price (always QUOTE_CURRENCY_DECIMALS)
    /// @dev Tries custom price source first, falls back to PriceOracleMiddleware if no custom source is set
    /// @dev Reverts if:
    /// @dev - asset_ is zero address
    /// @dev - price <= 0
    /// @dev - no custom price source is set and PriceOracleMiddleware reverts
    function _getAssetPrice(address asset_) private view returns (uint256 assetPrice, uint256 decimals) {
        if (asset_ == address(0)) {
            revert UnsupportedAsset();
        }

        address source = PriceOracleMiddlewareManagerLib.getSourceOfAssetPrice(asset_);
        int256 priceFeedPrice;
        uint256 priceFeedDecimals;

        if (source != address(0)) {
            // Use custom source directly
            try IPriceFeed(source).latestRoundData() returns (
                uint80 /*roundId*/,
                int256 price,
                uint256 /*startedAt*/,
                uint256 /*timestamp*/,
                uint80 /*answeredInRound*/
            ) {
                priceFeedPrice = price;
            } catch {
                revert UnexpectedPriceResult(); // Custom feed failed
            }

            try IPriceFeed(source).decimals() returns (uint8 customDecimals) {
                priceFeedDecimals = customDecimals;
            } catch {
                revert UnexpectedPriceResult(); // Custom feed decimals call failed
            }

            // Convert price to standard 18 decimals
            assetPrice = IporMath.convertToWad(priceFeedPrice.toUint256(), priceFeedDecimals);

            if (assetPrice <= 0) {
                revert UnexpectedPriceResult();
            }

            decimals = QUOTE_CURRENCY_DECIMALS;
        } else {
            // No custom source, delegate to PriceOracleMiddleware
            address middleware = PriceOracleMiddlewareManagerLib.getPriceOracleMiddleware();
            if (middleware == address(0)) {
                // Should not happen if constructor validation is correct, but good practice
                revert InvalidPriceOracleMiddleware();
            }

            // Let PriceOracleMiddleware handle Chainlink fallback and validation
            // Errors from middleware (like UnsupportedAsset, UnexpectedPriceResult) will propagate
            (assetPrice, decimals) = IPriceOracleMiddleware(middleware).getAssetPrice(asset_);

            // Middleware should ideally return 18 decimals, but handle conversion if necessary
            if (decimals != QUOTE_CURRENCY_DECIMALS) {
                // Convert the price received from middleware to the standard 18 decimals
                assetPrice = IporMath.convertToWad(assetPrice, decimals);
                decimals = QUOTE_CURRENCY_DECIMALS; // Update decimals to reflect the conversion
            }
            if (assetPrice <= 0) {
                revert UnexpectedPriceResult();
            }
        }
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AccessManagedUpgradeable} from "../access/AccessManagedUpgradeable.sol";
import {ContextClient} from "../context/ContextClient.sol";
import {UniversalReader} from "../../universal_reader/UniversalReader.sol";
import {PriceOracleMiddlewareManagerLib} from "./PriceOracleMiddlewareManagerLib.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IPriceFeed} from "../../price_oracle/price_feed/IPriceFeed.sol";
import {SequencerUptimeLib} from "./SequencerUptimeLib.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/// @title Price Oracle Middleware Manager
/// @notice Manages price sources for assets and provides price information
/// @dev This contract is responsible for managing price feeds and providing price information to the system
/// @dev Access control is managed through roles:
/// @dev - PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE: Can set and remove asset price sources
/// @dev - ATOMIST_ROLE: Can set the price oracle middleware address
contract PriceOracleMiddlewareManager is Initializable, AccessManagedUpgradeable, ContextClient, UniversalReader {
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

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @notice Constructor that initializes the PriceOracleMiddlewareManager with authority and price oracle middleware
    /// @dev Used when deploying directly without proxy
    /// @param initialAuthority_ The address that will be granted authority to manage access control
    /// @param priceOracleMiddleware_ The address of the price oracle middleware that will be used
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address initialAuthority_, address priceOracleMiddleware_) initializer {
        _initialize(initialAuthority_, priceOracleMiddleware_);
    }

    /// @notice Initializes the PriceOracleMiddlewareManager with authority and price oracle middleware
    /// @param initialAuthority_ The address of the initial authority
    /// @param priceOracleMiddleware_ The address of the price oracle middleware
    /// @dev This method is called after cloning to initialize the contract
    function proxyInitialize(address initialAuthority_, address priceOracleMiddleware_) external initializer {
        _initialize(initialAuthority_, priceOracleMiddleware_);
    }

    function _initialize(address initialAuthority_, address priceOracleMiddleware_) private {
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
    /// @dev Only callable by addresses with PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE
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
    /// @dev Only callable by addresses with PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE
    function removeAssetsPriceSources(address[] calldata assets_) external restricted {
        uint256 assetsLength = assets_.length;

        if (assetsLength == 0) {
            revert EmptyArrayNotSupported();
        }

        for (uint256 i; i < assetsLength; ++i) {
            PriceOracleMiddlewareManagerLib.removeAssetPriceSource(assets_[i]);
        }
    }

    /// @notice Sets the price oracle middleware address
    /// @param priceOracleMiddleware_ The new price oracle middleware address
    /// @dev Only callable by addresses with ATOMIST_ROLE
    function setPriceOracleMiddleware(address priceOracleMiddleware_) external restricted {
        PriceOracleMiddlewareManagerLib.setPriceOracleMiddleware(priceOracleMiddleware_);
    }

    /// @notice Gets the current price oracle middleware address
    /// @return The address of the current price oracle middleware
    function getPriceOracleMiddleware() external view returns (address) {
        return PriceOracleMiddlewareManagerLib.getPriceOracleMiddleware();
    }

    /// @notice Gets the price feed source address for a specific asset
    /// @param asset_ The address of the asset
    /// @return The address of the price feed source for the asset
    function getSourceOfAssetPrice(address asset_) external view returns (address) {
        return PriceOracleMiddlewareManagerLib.getSourceOfAssetPrice(asset_);
    }

    /// @notice Gets the list of all configured assets
    /// @return Array of configured asset addresses
    function getConfiguredAssets() external view returns (address[] memory) {
        return PriceOracleMiddlewareManagerLib.getConfiguredAssets();
    }

    /// @notice Updates max price delta threshold for a list of assets.
    /// @param assets_ Asset addresses to configure.
    /// @param maxPricesDelta_ Maximum price delta thresholds matching each asset.
    function updatePriceValidation(address[] calldata assets_, uint256[] calldata maxPricesDelta_) external restricted {
        uint256 assetsLength = assets_.length;
        if (assetsLength == 0) {
            revert EmptyArrayNotSupported();
        }
        if (assetsLength != maxPricesDelta_.length) {
            revert ArrayLengthMismatch();
        }
        for (uint256 i; i < assetsLength; ++i) {
            PriceOracleMiddlewareManagerLib.updatePriceValidation(assets_[i], maxPricesDelta_[i]);
        }
    }

    /// @notice Removes price validation configuration for provided assets.
    /// @param assets_ Asset addresses to clear.
    function removePriceValidation(address[] calldata assets_) external restricted {
        uint256 assetsLength = assets_.length;
        if (assetsLength == 0) {
            revert EmptyArrayNotSupported();
        }
        for (uint256 i; i < assetsLength; ++i) {
            PriceOracleMiddlewareManagerLib.removePriceValidation(assets_[i]);
        }
    }

    /// @notice Returns all assets with active price validation configuration.
    /// @return assets Array of asset addresses with configured validation.
    function getConfiguredPriceValidationAssets() external view returns (address[] memory assets) {
        assets = PriceOracleMiddlewareManagerLib.getConfiguredPriceValidationAssets();
    }

    function getPriceValidationInfo(
        address asset_
    ) external view returns (uint256 maxPricesDelta, uint256 lastValidatedPrice, uint256 lastValidatedTimestamp) {
        return PriceOracleMiddlewareManagerLib.getPriceValidationInfo(asset_);
    }

    function validateAllAssetsPrices() external restricted {
        address[] memory assets = PriceOracleMiddlewareManagerLib.getConfiguredPriceValidationAssets();
        uint256 assetsLength = assets.length;
        if (assetsLength == 0) {
            return;
        }

        uint256 assetPrice;
        uint256 decimals;

        for (uint256 i; i < assetsLength; ++i) {
            (assetPrice, decimals) = _getAssetPrice(assets[i]);
            PriceOracleMiddlewareManagerLib.validatePriceChange(assets[i], IporMath.convertToWad(assetPrice, decimals));
        }
    }

    function validateAssetsPrices(address[] calldata assets_) external restricted {
        uint256 assetsLength = assets_.length;
        uint256 assetPrice;
        uint256 decimals;

        if (assetsLength == 0) {
            return;
        }

        for (uint256 i; i < assetsLength; ++i) {
            (assetPrice, decimals) = _getAssetPrice(assets_[i]);
            PriceOracleMiddlewareManagerLib.validatePriceChange(
                assets_[i],
                IporMath.convertToWad(assetPrice, decimals)
            );
        }
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

    // ======================== Oracle Security Configuration ========================

    /// @notice Configures the L2 sequencer uptime feed for this vault
    /// @param sequencerFeed_ Address of the Chainlink Sequencer Uptime Feed (address(0) to disable)
    /// @param isOpStackFeed_ True for Base/OP Stack, false for Arbitrum
    function configureSequencerCheck(address sequencerFeed_, bool isOpStackFeed_) external restricted {
        PriceOracleMiddlewareManagerLib.setSequencerConfig(sequencerFeed_, isOpStackFeed_);
    }

    /// @notice Enables or disables the sequencer uptime check
    /// @param enabled_ True to enable, false to disable
    function setSequencerCheckEnabled(bool enabled_) external restricted {
        PriceOracleMiddlewareManagerLib.setSequencerCheckEnabled(enabled_);
    }

    /// @notice Returns the current sequencer configuration
    function getSequencerConfig() external view returns (address feed, bool isOpStack, bool enabled) {
        return PriceOracleMiddlewareManagerLib.getSequencerConfig();
    }

    /// @notice Sets per-asset staleness thresholds (in seconds)
    /// @param assets_ Asset addresses to configure
    /// @param maxStaleness_ Maximum staleness in seconds for each asset (0 = disable for that asset)
    function setAssetsStalenessThresholds(
        address[] calldata assets_,
        uint256[] calldata maxStaleness_
    ) external restricted {
        uint256 assetsLength = assets_.length;
        if (assetsLength == 0) {
            revert EmptyArrayNotSupported();
        }
        if (assetsLength != maxStaleness_.length) {
            revert ArrayLengthMismatch();
        }
        for (uint256 i; i < assetsLength; ++i) {
            PriceOracleMiddlewareManagerLib.setAssetStaleness(assets_[i], maxStaleness_[i]);
        }
    }

    /// @notice Removes staleness thresholds for specified assets
    /// @param assets_ Asset addresses to clear
    function removeAssetsStalenessThresholds(address[] calldata assets_) external restricted {
        uint256 assetsLength = assets_.length;
        if (assetsLength == 0) {
            revert EmptyArrayNotSupported();
        }
        for (uint256 i; i < assetsLength; ++i) {
            PriceOracleMiddlewareManagerLib.removeAssetStaleness(assets_[i]);
        }
    }

    /// @notice Sets the default staleness threshold used when no per-asset config exists
    /// @param defaultMaxStaleness_ Default max staleness in seconds (0 = no global default)
    function setDefaultStalenessThreshold(uint256 defaultMaxStaleness_) external restricted {
        PriceOracleMiddlewareManagerLib.setDefaultStaleness(defaultMaxStaleness_);
    }

    /// @notice Returns the effective staleness threshold for an asset (per-asset or default fallback)
    function getAssetStalenessThreshold(address asset_) external view returns (uint256) {
        return PriceOracleMiddlewareManagerLib.getAssetMaxStaleness(asset_);
    }

    /// @notice Returns the default staleness threshold
    function getDefaultStalenessThreshold() external view returns (uint256) {
        return PriceOracleMiddlewareManagerLib.getAssetMaxStaleness(address(0));
    }

    /// @notice Sets per-asset price bounds (in WAD = 18 decimals)
    /// @param assets_ Asset addresses to configure
    /// @param minPrices_ Minimum acceptable price for each asset (0 = no floor)
    /// @param maxPrices_ Maximum acceptable price for each asset (0 = no ceiling)
    function setAssetsPriceBounds(
        address[] calldata assets_,
        uint256[] calldata minPrices_,
        uint256[] calldata maxPrices_
    ) external restricted {
        uint256 assetsLength = assets_.length;
        if (assetsLength == 0) {
            revert EmptyArrayNotSupported();
        }
        if (assetsLength != minPrices_.length || assetsLength != maxPrices_.length) {
            revert ArrayLengthMismatch();
        }
        for (uint256 i; i < assetsLength; ++i) {
            PriceOracleMiddlewareManagerLib.setAssetPriceBounds(assets_[i], minPrices_[i], maxPrices_[i]);
        }
    }

    /// @notice Removes price bounds for specified assets
    /// @param assets_ Asset addresses to clear
    function removeAssetsPriceBounds(address[] calldata assets_) external restricted {
        uint256 assetsLength = assets_.length;
        if (assetsLength == 0) {
            revert EmptyArrayNotSupported();
        }
        for (uint256 i; i < assetsLength; ++i) {
            PriceOracleMiddlewareManagerLib.removeAssetPriceBounds(assets_[i]);
        }
    }

    /// @notice Returns the price bounds for an asset
    function getAssetPriceBounds(address asset_) external view returns (uint256 minPrice, uint256 maxPrice) {
        return PriceOracleMiddlewareManagerLib.getAssetPriceBounds(asset_);
    }

    // ======================== Internal Price Logic ========================

    /// @notice Internal function to get asset price with security checks
    /// @param asset_ The address of the asset to price
    /// @return assetPrice The price in USD (with QUOTE_CURRENCY_DECIMALS decimals)
    /// @return decimals The number of decimals in the returned price (always QUOTE_CURRENCY_DECIMALS)
    function _getAssetPrice(address asset_) private view returns (uint256 assetPrice, uint256 decimals) {
        if (asset_ == address(0)) {
            revert UnsupportedAsset();
        }

        // Sequencer uptime check (if configured)
        (address sequencerFeed, bool isOpStack, bool sequencerEnabled) = PriceOracleMiddlewareManagerLib
            .getSequencerConfig();
        if (sequencerEnabled) {
            SequencerUptimeLib.checkSequencerUptime(sequencerFeed, isOpStack);
        }

        address source = PriceOracleMiddlewareManagerLib.getSourceOfAssetPrice(asset_);
        int256 priceFeedPrice;
        uint256 priceFeedDecimals;
        uint256 updatedAt;

        if (source != address(0)) {
            // Use custom source directly — capture updatedAt for staleness check
            try IPriceFeed(source).latestRoundData() returns (
                uint80 /*roundId*/,
                int256 price,
                uint256 /*startedAt*/,
                uint256 timestamp,
                uint80 /*answeredInRound*/
            ) {
                priceFeedPrice = price;
                updatedAt = timestamp;
            } catch {
                revert UnexpectedPriceResult();
            }

            try IPriceFeed(source).decimals() returns (uint8 customDecimals) {
                priceFeedDecimals = customDecimals;
            } catch {
                revert UnexpectedPriceResult();
            }

            // Convert price to standard 18 decimals
            assetPrice = IporMath.convertToWad(priceFeedPrice.toUint256(), priceFeedDecimals);

            if (assetPrice == 0) {
                revert UnexpectedPriceResult();
            }

            decimals = QUOTE_CURRENCY_DECIMALS;

            // Staleness check (per-asset or default, only if updatedAt is available)
            uint256 maxStaleness = PriceOracleMiddlewareManagerLib.getAssetMaxStaleness(asset_);
            if (maxStaleness > 0 && updatedAt > 0) {
                if (block.timestamp - updatedAt > maxStaleness) {
                    revert PriceOracleMiddlewareManagerLib.StalePrice(asset_, updatedAt, maxStaleness);
                }
            }
        } else {
            // No custom source, delegate to PriceOracleMiddleware
            address middleware = PriceOracleMiddlewareManagerLib.getPriceOracleMiddleware();
            if (middleware == address(0)) {
                revert InvalidPriceOracleMiddleware();
            }

            (assetPrice, decimals) = IPriceOracleMiddleware(middleware).getAssetPrice(asset_);

            if (decimals != QUOTE_CURRENCY_DECIMALS) {
                assetPrice = IporMath.convertToWad(assetPrice, decimals);
                decimals = QUOTE_CURRENCY_DECIMALS;
            }
            if (assetPrice == 0) {
                revert UnexpectedPriceResult();
            }
        }

        // Price bounds check (applies to both custom source and middleware paths)
        (uint256 minPrice, uint256 maxPrice) = PriceOracleMiddlewareManagerLib.getAssetPriceBounds(asset_);
        if (minPrice > 0 && assetPrice < minPrice) {
            revert PriceOracleMiddlewareManagerLib.PriceOutOfBounds(asset_, assetPrice, minPrice, maxPrice);
        }
        if (maxPrice > 0 && assetPrice > maxPrice) {
            revert PriceOracleMiddlewareManagerLib.PriceOutOfBounds(asset_, assetPrice, minPrice, maxPrice);
        }
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
struct AssetsPricesSources {
    /// @dev Maps asset addresses to their corresponding price feed addresses
    mapping(address asset => address priceFeed) sources;
    address[] assets;
}

struct PriceValidation {
    /// @dev The price change is recorded in percentages where 1e18 = 100%.
    mapping(address asset => uint256 maxPriceDelta) maxPriceDeltas;
    mapping(address asset => uint256 lastValidatedPrice) lastValidatedPrices;
    /// @dev Not implemented yet
    mapping(address asset => uint256 lastValidatedTimestamp) lastValidatedTimestamps;
    EnumerableSet.AddressSet assets;
}

struct PriceOracle {
    address priceOracle;
}

/// @dev Packed price bounds for a single asset (fits in one storage slot)
struct PriceBounds {
    /// @dev Minimum acceptable price in WAD (0 = no floor), max ~3.4e38
    uint128 minPrice;
    /// @dev Maximum acceptable price in WAD (0 = no ceiling), max ~3.4e38
    uint128 maxPrice;
}

struct OracleSecurityConfig {
    /// @dev Chainlink Sequencer Uptime Feed address (address(0) = disabled)
    /// @dev Packed in slot with isOpStackFeed (1B) + sequencerCheckEnabled (1B) + defaultMaxStaleness (6B) = 28B
    address sequencerUptimeFeed;
    /// @dev True for Base/OP Stack, false for Arbitrum
    bool isOpStackFeed;
    /// @dev Owner can disable sequencer check
    bool sequencerCheckEnabled;
    /// @dev Fallback staleness threshold in seconds (0 = no global default, max ~8.9M years)
    uint48 defaultMaxStaleness;
    /// @dev Per-asset maximum staleness in seconds (0 = disabled for that asset)
    mapping(address asset => uint256 maxStaleness) maxStaleness;
    /// @dev Per-asset price bounds packed as (uint128 minPrice, uint128 maxPrice) in a single slot
    mapping(address asset => PriceBounds) priceBounds;
}

library PriceOracleMiddlewareManagerLib {
    using EnumerableSet for EnumerableSet.AddressSet;
    /// @dev Error thrown when attempting to set a zero address as price source
    error SourceAddressCanNotBeZero();
    /// @dev Error thrown when attempting to set a price source for zero asset address
    error AssetsAddressCanNotBeZero();

    /// @dev Error thrown when attempting to set a zero address as price oracle middleware
    error PriceOracleMiddlewareCanNotBeZero();

    /// @dev Error thrown when attempting to set a zero max price delta
    /// @param maxPriceDelta The maximum allowed price delta
    error MaxPriceDeltaCanNotBeZero(uint256 maxPriceDelta);

    /// @dev Error thrown when attempting to validate price for an asset without configuration.
    /// @param asset Asset without configured validation.
    error PriceValidationNotConfigured(address asset);

    /// @dev Error thrown when price change for an asset exceeds the configured delta.
    /// @param asset Asset address.
    /// @param previousPrice Last validated price.
    /// @param newPrice Price proposed for validation.
    /// @param maxPriceDelta Maximum allowed price delta.
    error PriceChangeExceeded(address asset, uint256 previousPrice, uint256 newPrice, uint256 maxPriceDelta);

    event PriceOracleMiddlewareSet(address priceOracleMiddleware);

    event AssetPriceSourceAdded(address asset, address source);
    event AssetPriceSourceRemoved(address asset);

    event PriceValidationRemoved(address asset);

    event PriceValidationBaselineUpdated(address asset, uint256 price);

    /// @notice Emitted when price validation configuration is updated for an asset.
    /// @param asset Asset address with updated configuration.
    /// @param maxPriceDelta Maximum allowed price delta configured for the asset.
    event PriceValidationUpdated(address asset, uint256 maxPriceDelta);

    // Oracle Security errors
    error StalePrice(address asset, uint256 updatedAt, uint256 maxStaleness);
    error PriceOutOfBounds(address asset, uint256 price, uint256 minPrice, uint256 maxPrice);
    error MinPriceAboveMaxPrice(uint256 minPrice, uint256 maxPrice);

    // Oracle Security events
    event SequencerConfigSet(address feed, bool isOpStack);
    event SequencerCheckEnabledSet(bool enabled);
    event AssetStalenessSet(address asset, uint256 maxStaleness);
    event AssetStalenessRemoved(address asset);
    event DefaultStalenessSet(uint256 defaultMaxStaleness);
    event AssetPriceBoundsSet(address asset, uint256 minPrice, uint256 maxPrice);
    event AssetPriceBoundsRemoved(address asset);

    /// @dev Storage slot for assets price sources mapping
    /// @dev Computed as: keccak256(abi.encode(uint256(keccak256("io.ipor.priceOracleManager.AssetsPricesSources")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ASSETS_PRICES_SOURCES = 0xbc7b173cf41b66df25801705abbfb53e317f15848d6d19b9b70f825d127da300;

    /// @dev Storage slot for price oracle middleware address
    /// @dev Computed as: keccak256(abi.encode(uint256(keccak256("io.ipor.priceOracle.PriceOracleMiddleware")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PRICES_ORACLE_MIDDLEWARE =
        0x722e31f2085db8f1738654bffa04bc73275abca3504518d5cfb46903bed30d00;

    /// @dev Storage slot for price validation
    /// @dev Computed as: keccak256(abi.encode(uint256(keccak256("io.ipor.priceOracleManager.PriceValidation")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PRICE_VALIDATION_SLOT = 0x3a824addd7109b2e3c773a32f64f1d2526ce6e5a09fab1aeb4bf87a74d878200;

    /// @dev Storage slot for oracle security configuration
    /// @dev Computed as: keccak256(abi.encode(uint256(keccak256("io.ipor.priceOracleManager.OracleSecurityConfig")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ORACLE_SECURITY_CONFIG_SLOT =
        0xd8aed5716bbca04c31ebecb7327e8139add85b48e1b4a9855fbfa7939c9e7900;

    function getSourceOfAssetPrice(address asset_) internal view returns (address source) {
        return _getAssetsPricesSourcesSlot().sources[asset_];
    }

    function getConfiguredAssets() internal view returns (address[] memory assets) {
        return _getAssetsPricesSourcesSlot().assets;
    }

    function addAssetPriceSource(address asset_, address source_) internal {
        if (asset_ == address(0)) {
            revert AssetsAddressCanNotBeZero();
        }
        if (source_ == address(0)) {
            revert SourceAddressCanNotBeZero();
        }

        if (_getAssetsPricesSourcesSlot().sources[asset_] == address(0)) {
            _getAssetsPricesSourcesSlot().assets.push(asset_);
        }

        _getAssetsPricesSourcesSlot().sources[asset_] = source_;

        emit AssetPriceSourceAdded(asset_, source_);
    }

    function removeAssetPriceSource(address asset_) internal {
        AssetsPricesSources storage assetsPricesSources = _getAssetsPricesSourcesSlot();
        delete assetsPricesSources.sources[asset_];

        // Find and remove the asset from the array
        address[] storage assets = assetsPricesSources.assets;
        uint256 assetsLength = assets.length;
        for (uint256 i; i < assetsLength; i++) {
            if (assets[i] == asset_) {
                // Move the last element to the current position
                assets[i] = assets[assetsLength - 1];
                // Remove the last element
                assets.pop();
                break;
            }
        }

        emit AssetPriceSourceRemoved(asset_);
    }

    function setPriceOracleMiddleware(address priceOracleMiddleware_) internal {
        if (priceOracleMiddleware_ == address(0)) {
            revert PriceOracleMiddlewareCanNotBeZero();
        }

        _getPriceOracleSlot().priceOracle = priceOracleMiddleware_;

        emit PriceOracleMiddlewareSet(priceOracleMiddleware_);
    }

    function getPriceOracleMiddleware() internal view returns (address) {
        return _getPriceOracleSlot().priceOracle;
    }

    /// @notice Updates max price delta configuration for an asset and registers the asset if needed.
    /// @param asset_ Asset address to update.
    /// @param maxPriceDelta_ Maximum allowed price delta for the asset.
    function updatePriceValidation(address asset_, uint256 maxPriceDelta_) internal {
        if (asset_ == address(0)) {
            revert AssetsAddressCanNotBeZero();
        }
        if (maxPriceDelta_ == 0) {
            revert MaxPriceDeltaCanNotBeZero(maxPriceDelta_);
        }

        PriceValidation storage priceValidation = _getPriceValidationSlot();
        priceValidation.maxPriceDeltas[asset_] = maxPriceDelta_;
        priceValidation.assets.add(asset_);

        emit PriceValidationUpdated(asset_, maxPriceDelta_);
    }

    /// @notice Removes price validation configuration for an asset and clears stored data.
    /// @param asset_ Asset address to clear.
    function removePriceValidation(address asset_) internal {
        if (asset_ == address(0)) {
            revert AssetsAddressCanNotBeZero();
        }

        PriceValidation storage priceValidation = _getPriceValidationSlot();
        priceValidation.assets.remove(asset_);

        delete priceValidation.maxPriceDeltas[asset_];
        delete priceValidation.lastValidatedPrices[asset_];

        emit PriceValidationRemoved(asset_);
    }

    function isPriceValidationSupported(address asset_) internal view returns (bool) {
        return _getPriceValidationSlot().assets.contains(asset_);
    }

    function getConfiguredPriceValidationAssets() internal view returns (address[] memory) {
        return _getPriceValidationSlot().assets.values();
    }

    function getPriceValidationInfo(
        address asset_
    ) internal view returns (uint256 maxPriceDelta, uint256 lastValidatedPrice, uint256 lastValidatedTimestamp) {
        return (
            _getPriceValidationSlot().maxPriceDeltas[asset_],
            _getPriceValidationSlot().lastValidatedPrices[asset_],
            _getPriceValidationSlot().lastValidatedTimestamps[asset_]
        );
    }

    /// @notice Validates price change for an asset against configured delta.
    /// @param asset_ Asset address under validation.
    /// @param price_ Current price expressed in 18 decimals.
    /// @return baselineUpdated True when stored baseline was updated with the new price.
    function validatePriceChange(address asset_, uint256 price_) internal returns (bool baselineUpdated) {
        if (asset_ == address(0)) {
            revert AssetsAddressCanNotBeZero();
        }

        PriceValidation storage priceValidation = _getPriceValidationSlot();

        if (!priceValidation.assets.contains(asset_)) {
            revert PriceValidationNotConfigured(asset_);
        }

        uint256 maxPriceDelta = priceValidation.maxPriceDeltas[asset_];
        if (maxPriceDelta == 0) {
            revert MaxPriceDeltaCanNotBeZero(maxPriceDelta);
        }

        uint256 lastValidatedPrice = priceValidation.lastValidatedPrices[asset_];
        if (lastValidatedPrice == 0) {
            priceValidation.lastValidatedPrices[asset_] = price_;
            emit PriceValidationBaselineUpdated(asset_, price_);
            return true;
        }

        uint256 priceDifference = price_ > lastValidatedPrice
            ? price_ - lastValidatedPrice
            : lastValidatedPrice - price_;

        uint256 priceDifferencePercent = Math.mulDiv(priceDifference, 1e18, lastValidatedPrice);

        if (priceDifferencePercent > maxPriceDelta) {
            revert PriceChangeExceeded(asset_, lastValidatedPrice, price_, maxPriceDelta);
        }

        if (priceDifferencePercent > maxPriceDelta / 2) {
            priceValidation.lastValidatedPrices[asset_] = price_;
            emit PriceValidationBaselineUpdated(asset_, price_);
            return true;
        }
    }

    // ======================== Oracle Security Config ========================

    function setSequencerConfig(address feed_, bool isOpStack_) internal {
        OracleSecurityConfig storage config = _getOracleSecurityConfigSlot();
        config.sequencerUptimeFeed = feed_;
        config.isOpStackFeed = isOpStack_;
        if (feed_ != address(0)) {
            config.sequencerCheckEnabled = true;
        }
        emit SequencerConfigSet(feed_, isOpStack_);
    }

    function setSequencerCheckEnabled(bool enabled_) internal {
        _getOracleSecurityConfigSlot().sequencerCheckEnabled = enabled_;
        emit SequencerCheckEnabledSet(enabled_);
    }

    function getSequencerConfig() internal view returns (address feed, bool isOpStack, bool enabled) {
        OracleSecurityConfig storage config = _getOracleSecurityConfigSlot();
        return (config.sequencerUptimeFeed, config.isOpStackFeed, config.sequencerCheckEnabled);
    }

    function setAssetStaleness(address asset_, uint256 maxStaleness_) internal {
        if (asset_ == address(0)) {
            revert AssetsAddressCanNotBeZero();
        }
        _getOracleSecurityConfigSlot().maxStaleness[asset_] = maxStaleness_;
        emit AssetStalenessSet(asset_, maxStaleness_);
    }

    function removeAssetStaleness(address asset_) internal {
        if (asset_ == address(0)) {
            revert AssetsAddressCanNotBeZero();
        }
        delete _getOracleSecurityConfigSlot().maxStaleness[asset_];
        emit AssetStalenessRemoved(asset_);
    }

    function setDefaultStaleness(uint256 defaultMaxStaleness_) internal {
        _getOracleSecurityConfigSlot().defaultMaxStaleness = SafeCast.toUint48(defaultMaxStaleness_);
        emit DefaultStalenessSet(defaultMaxStaleness_);
    }

    function getAssetMaxStaleness(address asset_) internal view returns (uint256) {
        OracleSecurityConfig storage config = _getOracleSecurityConfigSlot();
        uint256 assetStaleness = config.maxStaleness[asset_];
        if (assetStaleness > 0) {
            return assetStaleness;
        }
        return config.defaultMaxStaleness;
    }

    function setAssetPriceBounds(address asset_, uint256 minPrice_, uint256 maxPrice_) internal {
        if (asset_ == address(0)) {
            revert AssetsAddressCanNotBeZero();
        }
        if (minPrice_ > maxPrice_ && maxPrice_ > 0) {
            revert MinPriceAboveMaxPrice(minPrice_, maxPrice_);
        }
        OracleSecurityConfig storage config = _getOracleSecurityConfigSlot();
        config.priceBounds[asset_] = PriceBounds({
            minPrice: SafeCast.toUint128(minPrice_),
            maxPrice: SafeCast.toUint128(maxPrice_)
        });
        emit AssetPriceBoundsSet(asset_, minPrice_, maxPrice_);
    }

    function removeAssetPriceBounds(address asset_) internal {
        if (asset_ == address(0)) {
            revert AssetsAddressCanNotBeZero();
        }
        delete _getOracleSecurityConfigSlot().priceBounds[asset_];
        emit AssetPriceBoundsRemoved(asset_);
    }

    function getAssetPriceBounds(address asset_) internal view returns (uint256 minPrice, uint256 maxPrice) {
        PriceBounds storage bounds = _getOracleSecurityConfigSlot().priceBounds[asset_];
        return (bounds.minPrice, bounds.maxPrice);
    }

    // ======================== Private Slot Accessors ========================

    function _getOracleSecurityConfigSlot() private pure returns (OracleSecurityConfig storage config) {
        assembly {
            config.slot := ORACLE_SECURITY_CONFIG_SLOT
        }
    }

    function _getAssetsPricesSourcesSlot() private pure returns (AssetsPricesSources storage assetsPricesSources) {
        assembly {
            assetsPricesSources.slot := ASSETS_PRICES_SOURCES
        }
    }

    function _getPriceOracleSlot() private pure returns (PriceOracle storage priceOracle) {
        assembly {
            priceOracle.slot := PRICES_ORACLE_MIDDLEWARE
        }
    }

    function _getPriceValidationSlot() private pure returns (PriceValidation storage priceValidation) {
        assembly {
            priceValidation.slot := PRICE_VALIDATION_SLOT
        }
    }
}

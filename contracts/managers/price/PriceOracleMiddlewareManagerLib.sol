// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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
    function removePriceValidations(address asset_) internal {
        if (asset_ == address(0)) {
            revert AssetsAddressCanNotBeZero();
        }

        PriceValidation storage priceValidation = _getPriceValidationSlot();
        priceValidation.assets.remove(asset_);

        delete priceValidation.maxPriceDeltas[asset_];
        delete priceValidation.lastValidatedPrices[asset_];

        emit PriceValidationRemoved(asset_);
    }

    function shouldValidatePrice(address asset_) internal view returns (bool) {
        return _getPriceValidationSlot().assets.contains(asset_);
    }

    function getAllValidatedAssets() internal view returns (address[] memory) {
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

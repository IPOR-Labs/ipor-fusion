// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

struct AssetsPricesSources {
    /// @dev Maps asset addresses to their corresponding price feed addresses
    mapping(address asset => address priceFeed) sources;
    address[] assets;
}

struct PriceOracle {
    address priceOracle;
}

library PriceOracleMiddlewareManagerLib {
    /// @dev Error thrown when attempting to set a zero address as price source
    error SourceAddressCanNotBeZero();
    /// @dev Error thrown when attempting to set a price source for zero asset address
    error AssetsAddressCanNotBeZero();

    /// @dev Error thrown when attempting to set a zero address as price oracle middleware
    error PriceOracleMiddlewareCanNotBeZero();

    event PriceOracleMiddlewareSet(address indexed priceOracleMiddleware);

    event AssetPriceSourceAdded(address indexed asset, address indexed source);
    event AssetPriceSourceRemoved(address indexed asset);

    /// @dev Storage slot for assets price sources mapping
    /// @dev Computed as: keccak256(abi.encode(uint256(keccak256("io.ipor.priceOracleManager.AssetsPricesSources")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ASSETS_PRICES_SOURCES = 0xbc7b173cf41b66df25801705abbfb53e317f15848d6d19b9b70f825d127da300;

    /// @dev Storage slot for price oracle middleware address
    /// @dev Computed as: keccak256(abi.encode(uint256(keccak256("io.ipor.priceOracle.PriceOracleMiddleware")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PRICES_ORACLE_MIDDLEWARE =
        0x722e31f2085db8f1738654bffa04bc73275abca3504518d5cfb46903bed30d00;

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
}

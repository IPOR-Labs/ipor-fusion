// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title PriceOracleMiddlewareStorageLib
/// @notice Storage library for managing price feed sources for assets in the Price Oracle system
/// @dev Implements ERC-7201 namespaced storage pattern for price feed mappings
library PriceOracleMiddlewareStorageLib {
    /// @dev Storage slot for assets price sources mapping
    /// @dev Computed as: keccak256(abi.encode(uint256(keccak256("io.ipor.priceOracle.AssetsPricesSources")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ASSETS_PRICES_SOURCES = 0xefe839ce0caa5648581e30daa19dcc84419e945902cc17f7f481f056193edd00;

    /// @dev Storage structure for assets price sources following ERC-7201 pattern
    /// @custom:storage-location erc7201:io.ipor.priceOracle.AssetsPricesSources
    struct AssetsPricesSources {
        /// @dev Maps asset addresses to their corresponding price feed addresses
        mapping(address asset => address priceFeed) value;
    }

    /// @dev Emitted when a price source for an asset is updated
    /// @param asset The address of the asset whose price source was updated
    /// @param source The new price feed source address
    event AssetPriceSourceUpdated(address asset, address source);

    /// @dev Error thrown when attempting to set a zero address as price source
    error SourceAddressCanNotBeZero();
    /// @dev Error thrown when attempting to set a price source for zero asset address
    error AssetsAddressCanNotBeZero();

    /// @notice Retrieves the price feed source address for a given asset
    /// @param asset_ The address of the asset to query
    /// @return source The address of the price feed source for the asset
    /// @dev Returns address(0) if no price source is set for the asset
    function getSourceOfAssetPrice(address asset_) internal view returns (address source) {
        return _getAssetsPricesSources().value[asset_];
    }

    /// @notice Sets or updates the price feed source for an asset
    /// @param asset_ The address of the asset to set the price source for
    /// @param source_ The address of the price feed source
    /// @dev Emits AssetPriceSourceUpdated event on successful update
    /// @dev Reverts if either asset_ or source_ is zero address
    function setAssetPriceSource(address asset_, address source_) internal {
        if (asset_ == address(0)) {
            revert AssetsAddressCanNotBeZero();
        }
        if (source_ == address(0)) {
            revert SourceAddressCanNotBeZero();
        }

        address oldSource = _getAssetsPricesSources().value[asset_];
        // Avoid unnecessary storage writes and events if the source hasn't changed
        if (oldSource != source_) {
            _getAssetsPricesSources().value[asset_] = source_;
            emit AssetPriceSourceUpdated(asset_, source_);
        }
    }

    /// @dev Internal function to access the storage slot for assets price sources
    /// @return assetsPricesSources The storage reference to AssetsPricesSources struct
    function _getAssetsPricesSources() private pure returns (AssetsPricesSources storage assetsPricesSources) {
        assembly {
            assetsPricesSources.slot := ASSETS_PRICES_SOURCES
        }
    }
}

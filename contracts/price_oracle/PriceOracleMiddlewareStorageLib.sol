// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title PriceOracleMiddlewareStorageLib
/// @notice Storage library for managing price feed sources for assets in the Price Oracle system
/// @dev Implements ERC-7201 namespaced storage pattern for price feed mappings
library PriceOracleMiddlewareStorageLib {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev Storage slot for assets price sources mapping
    /// @dev Do not change this value !!!
    bytes32 private constant ASSETS_PRICES_SOURCES = 0xefe839ce0caa5648581e30daa19dcc84419e945902cc17f7f481f056193edd00;

    /// @dev Storage structure for assets price sources following ERC-7201 pattern
    /// @custom:storage-location erc7201:io.ipor.priceOracle.AssetsPricesSources
    struct AssetsPricesSources {
        /// @dev Maps asset addresses to their corresponding price feed addresses
        mapping(address asset => address priceFeed) value;
    }

    /// @dev Storage slot for the set of trusted Pendle market factories
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.priceOracle.PendleMarketFactories")) - 1)) & ~bytes32(uint256(0xff))
    /// @dev Do not change this value !!!
    bytes32 private constant PENDLE_MARKET_FACTORIES =
        0x53d4a51401004c714bc12df9f19e6f479acc264fd594e584ce5de34f8e34a300;

    /// @dev Storage structure for the trusted Pendle market factories following ERC-7201 pattern
    /// @custom:storage-location erc7201:io.ipor.priceOracle.PendleMarketFactories
    struct PendleMarketFactories {
        /// @dev Set of Pendle market factories whose markets may be used for PT price feeds
        EnumerableSet.AddressSet factories;
    }

    /// @dev Emitted when a Pendle market factory is added to or removed from the trusted set
    /// @param factory The factory address
    /// @param allowed True when the factory was added, false when it was removed
    event PendleMarketFactoryUpdated(address factory, bool allowed);

    /// @dev Error thrown when attempting to register a zero address as a Pendle market factory
    error PendleMarketFactoryCanNotBeZero();

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

        if (oldSource != source_) {
            _getAssetsPricesSources().value[asset_] = source_;
            emit AssetPriceSourceUpdated(asset_, source_);
        }
    }

    /// @notice Adds or removes a trusted Pendle market factory
    /// @param factory_ The factory address
    /// @param allowed_ True to add, false to remove
    /// @dev Emits PendleMarketFactoryUpdated only when the membership actually changes
    function setPendleMarketFactory(address factory_, bool allowed_) internal {
        if (factory_ == address(0)) {
            revert PendleMarketFactoryCanNotBeZero();
        }
        EnumerableSet.AddressSet storage set = _getPendleMarketFactories().factories;
        bool changed = allowed_ ? set.add(factory_) : set.remove(factory_);
        if (changed) {
            emit PendleMarketFactoryUpdated(factory_, allowed_);
        }
    }

    /// @notice Returns true when the factory is in the trusted set
    function isPendleMarketFactory(address factory_) internal view returns (bool) {
        return _getPendleMarketFactories().factories.contains(factory_);
    }

    /// @notice Returns all trusted Pendle market factories
    function getPendleMarketFactories() internal view returns (address[] memory) {
        return _getPendleMarketFactories().factories.values();
    }

    /// @dev Internal function to access the storage slot for trusted Pendle market factories
    function _getPendleMarketFactories() private pure returns (PendleMarketFactories storage pendleMarketFactories) {
        bytes32 slot = PENDLE_MARKET_FACTORIES;
        assembly {
            pendleMarketFactories.slot := slot
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

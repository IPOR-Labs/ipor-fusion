// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title Storage library for PriceOracleMiddleware responsible for storing the price feed sources for assets
library PriceOracleMiddlewareStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.priceOracle.AssetsPricesSources")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant ASSETS_PRICES_SOURCES = 0xefe839ce0caa5648581e30daa19dcc84419e945902cc17f7f481f056193edd00;

    /// @custom:storage-location erc7201:io.ipor.priceOracle.AssetsPricesSources
    struct AssetsPricesSources {
        mapping(address asset => address priceFeed) value;
    }

    event AssetPriceSourceUpdated(address asset, address source);

    error SourceAddressCanNotBeZero();
    error AssetsAddressCanNotBeZero();

    /// @notice Retrieves the price feed source for the asset
    /// @param asset_ The address of the asset
    /// @return source The address of the source of the asset price
    function getSourceOfAssetPrice(address asset_) internal view returns (address source) {
        return _getAssetsPricesSources().value[asset_];
    }

    /// @notice Sets the sources of the asset prices
    /// @param asset_ The address of the asset
    /// @param source_ The address of the source of the asset price
    function setAssetPriceSource(address asset_, address source_) internal {
        if (asset_ == address(0)) {
            revert AssetsAddressCanNotBeZero();
        }

        if (source_ == address(0)) {
            revert SourceAddressCanNotBeZero();
        }

        _getAssetsPricesSources().value[asset_] = source_;

        emit AssetPriceSourceUpdated(asset_, source_);
    }

    function _getAssetsPricesSources() private pure returns (AssetsPricesSources storage assetsPricesSources) {
        assembly {
            assetsPricesSources.slot := ASSETS_PRICES_SOURCES
        }
    }
}

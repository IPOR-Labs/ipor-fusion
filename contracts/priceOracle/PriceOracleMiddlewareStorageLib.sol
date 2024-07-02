// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {Errors} from "../libraries/errors/Errors.sol";

/// @title Storage library for PriceOracleMiddleware
library PriceOracleMiddlewareStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.assetsPricesSources")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant ASSETS_PRICES_SOURCES = 0x8e0a28dd9d78e65e0eaab36f0d8ddba5c9c6478807c995fdcbb3e9d89078da00;

    /// @custom:storage-location erc7201:io.ipor.assetsSources
    struct AssetsPricesSources {
        mapping(address asset => address priceFeed) value;
    }

    event AssetPriceSourceUpdated(address indexed asset, address indexed source);

    error SourceAddressCanNotBeZero(string errorCode);
    error AssetsAddressCanNotBeZero(string errorCode);

    function getSourceOfAssetPrice(address asset_) internal view returns (address source) {
        return _getAssetsPricesSources().value[asset_];
    }

    function setAssetPriceSource(address asset_, address source_) internal {
        if (asset_ == address(0)) {
            revert AssetsAddressCanNotBeZero(Errors.UNSUPPORTED_ZERO_ADDRESS);
        }

        if (source_ == address(0)) {
            revert SourceAddressCanNotBeZero(Errors.UNSUPPORTED_ZERO_ADDRESS);
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

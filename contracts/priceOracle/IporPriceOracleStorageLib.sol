// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {Errors} from "../libraries/errors/Errors.sol";

/// @title Storage
library IporPriceOracleStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.assetsSources")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant ASSETS_SOURCES = 0xd12d38cc8fce64bbd07b3f1346bd7dd01071b1a6feaf308124f3fc4f8df3c000;

    /// @custom:storage-location erc7201:io.ipor.assetsSources
    struct AssetsSources {
        /// @dev asset => priceFead
        mapping(address => address) value;
    }

    event AssetSourceUpdated(address indexed asset, address indexed source);

    error SourceAddressCanNotBeZero(string errorCode);
    error AssetsAddressCanNotBeZero(string errorCode);

    function _getAssetsSources() private pure returns (AssetsSources storage grantedAssets) {
        assembly {
            grantedAssets.slot := ASSETS_SOURCES
        }
    }

    function getSourceOfAsset(address asset) internal view returns (address source) {
        return _getAssetsSources().value[asset];
    }

    function setAssetSource(address asset, address source) internal {
        if (source == address(0)) {
            revert SourceAddressCanNotBeZero(Errors.UNSUPPORTED_ZERO_ADDRESS);
        }
        if (asset == address(0)) {
            revert AssetsAddressCanNotBeZero(Errors.UNSUPPORTED_ZERO_ADDRESS);
        }
        _getAssetsSources().value[asset] = source;
        emit AssetSourceUpdated(asset, source);
    }
}

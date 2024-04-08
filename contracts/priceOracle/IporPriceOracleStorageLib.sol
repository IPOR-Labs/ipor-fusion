// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {Errors} from "../libraries/errors/Errors.sol";

/// @title Storage
library IporPriceOracleStorageLib {
    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.assetsSources")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant ASSETS_SOURCES = 0x7dd7151eda9a8aa729c84433daab8cd1eaf1f4ce42af566ab5ad0e56a8023100; // todo update value

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

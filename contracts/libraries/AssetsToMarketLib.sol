// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {StorageLib} from "./StorageLib.sol";

library AssetsToMarketLib {
    function grantAssetsToMarket(uint256 marketId, address[] memory assets) internal {
        StorageLib.MarketsGrantedAssets storage grantedAssets = StorageLib.getMarketsGrantedAssets();
        uint256 length = assets.length;
        for (uint256 i; i < length; ++i) {
            grantedAssets.value[marketId][assets[i]] = 1;
        }
    }

    function revokeAssetsFromMarket(uint256 marketId, address[] calldata assets) internal {
        StorageLib.MarketsGrantedAssets storage grantedAssets = StorageLib.getMarketsGrantedAssets();
        uint256 length = assets.length;
        for (uint256 i; i < length; ++i) {
            grantedAssets.value[marketId][assets[i]] = 0;
        }
    }

    function isAssetGrantedToMarket(uint256 marketId, address asset) internal view returns (bool) {
        return StorageLib.getMarketsGrantedAssets().value[marketId][asset] == 1;
    }

    function getAssetsFromMarket(uint256 marketId) internal view returns (address[] memory) {
        StorageLib.MarketsGrantedAssets storage grantedAssets = StorageLib.getMarketsGrantedAssets();
        //        uint256 length = grantedAssets.value[marketId].length;
        address[] memory assets = new address[](1);
        //        for (uint256 i; i < length; ++i) {
        //            assets[i] = grantedAssets.value[marketId][i];
        //        }
        return assets;
    }
}

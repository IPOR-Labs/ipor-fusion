// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import "../../contracts/libraries/AssetsToMarketLib.sol";

contract AssetsToMarketMock {
    function grantAssetsToMarket(uint256 marketId, address[] calldata assets) external {
        AssetsToMarketLib.grantAssetsToMarket(marketId, assets);
    }

    function revokeAssetsFromMarket(uint256 marketId, address[] calldata assets) external {
        AssetsToMarketLib.revokeAssetsFromMarket(marketId, assets);
    }

    function isAssetGrantedToMarket(uint256 marketId, address asset) external view returns (bool) {
        return AssetsToMarketLib.isAssetGrantedToMarket(marketId, asset);
    }
}

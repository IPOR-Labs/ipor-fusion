// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {AssetsToMarketMock} from "./AssetsToMarketMock.sol";

contract AssetsToMarketTest is Test {
    AssetsToMarketMock internal assetsToMarketMock;

    function setUp() public {
        assetsToMarketMock = new AssetsToMarketMock();
    }

    function testShouldGrantAssetsToMarket() public {
        // given
        address[] memory assets = new address[](2);
        assets[0] = address(0x1);
        assets[1] = address(0x2);

        // when
        assetsToMarketMock.grantAssetsToMarket(1, assets);

        // then
        assertTrue(assetsToMarketMock.isAssetGrantedToMarket(1, address(0x1)));
        assertTrue(assetsToMarketMock.isAssetGrantedToMarket(1, address(0x2)));
    }

    function testShouldRevokeAssetsFromMarket() public {
        // given
        address[] memory assets = new address[](2);
        assets[0] = address(0x1);
        assets[1] = address(0x2);
        assetsToMarketMock.grantAssetsToMarket(1, assets);
        bool asset1Before = assetsToMarketMock.isAssetGrantedToMarket(1, address(0x1));
        bool asset2Before = assetsToMarketMock.isAssetGrantedToMarket(1, address(0x2));

        // when
        assetsToMarketMock.revokeAssetsFromMarket(1, assets);

        // then
        assertFalse(assetsToMarketMock.isAssetGrantedToMarket(1, address(0x1)));
        assertFalse(assetsToMarketMock.isAssetGrantedToMarket(1, address(0x2)));
        assertTrue(asset1Before);
        assertTrue(asset2Before);
    }

    function testShouldNotHaveAccessToAssetsFromDifferentMarkets() public {
        // given
        address[] memory assets = new address[](2);
        assets[0] = address(0x1);
        assets[1] = address(0x2);
        assetsToMarketMock.grantAssetsToMarket(1, assets);

        // when
        bool asset1Before = assetsToMarketMock.isAssetGrantedToMarket(1, address(0x1));
        bool asset2Before = assetsToMarketMock.isAssetGrantedToMarket(1, address(0x2));
        bool asset3Before = assetsToMarketMock.isAssetGrantedToMarket(2, address(0x1));
        bool asset4Before = assetsToMarketMock.isAssetGrantedToMarket(2, address(0x2));

        // then
        assertTrue(asset1Before);
        assertTrue(asset2Before);
        assertFalse(asset3Before);
        assertFalse(asset4Before);
    }

    function testShouldNotHaveAccessWhenEmptyStorage() external {
        // when
        bool asset1Before = assetsToMarketMock.isAssetGrantedToMarket(1, address(0x1));
        bool asset2Before = assetsToMarketMock.isAssetGrantedToMarket(1, address(0x2));
        bool asset3Before = assetsToMarketMock.isAssetGrantedToMarket(2, address(0x1));
        bool asset4Before = assetsToMarketMock.isAssetGrantedToMarket(2, address(0x2));

        // then
        assertFalse(asset1Before);
        assertFalse(asset2Before);
        assertFalse(asset3Before);
        assertFalse(asset4Before);
    }
}

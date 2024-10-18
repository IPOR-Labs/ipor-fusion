// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AssetChainlinkPriceFeed} from "../../../contracts/price_oracle/price_feed/AssetChainlinkPriceFeed.sol";

contract RsETHAssetChainlinkPriceFeedArbitrumTest is Test {
    address public constant RS_ETH = 0xED65C5085a18Fa160Af0313E60dcc7905E944Dc7;
    address public constant RS_ETH_ETH_CHAINLINKG_FEED = 0xb0EA543f9F8d4B818550365d13F66Da747e1476A;
    address public constant ETH_USD_CHAINLINKG_FEED = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 264856395);
    }

    function testShouldReturnPrice() external {
        // given
        AssetChainlinkPriceFeed priceFeed = new AssetChainlinkPriceFeed(
            RS_ETH,
            RS_ETH_ETH_CHAINLINKG_FEED,
            ETH_USD_CHAINLINKG_FEED
        );

        // when
        (, int256 price, , , ) = priceFeed.latestRoundData();

        // then
        assertEq(uint256(price), uint256(266148959360), "Price should be calculated correctly");
    }
}

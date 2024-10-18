// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AssetChainlinkPriceFeed} from "../../../contracts/price_oracle/price_feed/AssetChainlinkPriceFeed.sol";

contract WstETHAssetChainlinkPriceFeedArbitrumTest is Test {
    address public constant WST_ETH = 0x5979D7b546E38E414F7E9822514be443A4800529;
    address public constant WST_ETH_ETH_CHAINLINKG_FEED = 0xb523AE262D20A936BC152e6023996e46FDC2A95D;
    address public constant ETH_USD_CHAINLINKG_FEED = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 264839604);
    }

    function testShouldReturnPrice() external {
        // given
        AssetChainlinkPriceFeed priceFeed = new AssetChainlinkPriceFeed(
            WST_ETH,
            WST_ETH_ETH_CHAINLINKG_FEED,
            ETH_USD_CHAINLINKG_FEED
        );

        // when
        (, int256 price, , , ) = priceFeed.latestRoundData();

        // then
        assertEq(uint256(price), uint256(305594160119), "Price should be calculated correctly");
    }
}

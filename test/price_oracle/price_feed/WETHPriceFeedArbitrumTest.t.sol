// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "../../../contracts/price_oracle/ext/AggregatorV3Interface.sol";
import {WETHPriceFeed} from "../../../contracts/price_oracle/price_feed/WETHPriceFeed.sol";

contract WETHPriceFeedArbitrumTest is Test {
    address public constant ETH_CHAINLINK_FEED = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 264760468);
    }

    function testShouldCalculateCorrectWEthPrice() external {
        // given
        WETHPriceFeed priceFeed = new WETHPriceFeed(ETH_CHAINLINK_FEED);

        (, int256 ethPrice, , , ) = AggregatorV3Interface(ETH_CHAINLINK_FEED).latestRoundData();

        // when
        (, int256 wETHprice, , , ) = priceFeed.latestRoundData();

        // then
        assertEq(ethPrice, wETHprice, "Price should be calculated correctly");
    }
}

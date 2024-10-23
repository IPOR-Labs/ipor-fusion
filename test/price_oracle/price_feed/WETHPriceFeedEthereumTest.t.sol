// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "../../../contracts/price_oracle/ext/AggregatorV3Interface.sol";
import {WETHPriceFeed} from "../../../contracts/price_oracle/price_feed/WETHPriceFeed.sol";

contract WETHPriceFeedArbitrumTest is Test {
    address public constant ETH_CHAINLINK_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 20985437);
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

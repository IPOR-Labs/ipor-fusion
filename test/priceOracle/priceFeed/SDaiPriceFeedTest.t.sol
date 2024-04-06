// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {SDaiPriceFeed} from "../../../contracts/priceOracle/priceFeed/SDaiPriceFeed.sol";

contract SDaiPriceFeedTest is Test {
    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19574589);
    }

    function testShouldReturnPrice() external {
        // given
        SDaiPriceFeed priceFeed = new SDaiPriceFeed();

        // when
        uint256 result = priceFeed.getLatestPrice();

        // then
        assertEq(result, uint256(106851828), "Price should be calculated correctly");
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SDaiPriceFeedEthereum} from "../../../contracts/priceOracle/priceFeed/SDaiPriceFeedEthereum.sol";

contract SDaiPriceFeedTest is Test {
    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19574589);
    }

    function testShouldReturnPrice() external {
        // given
        SDaiPriceFeedEthereum priceFeed = new SDaiPriceFeedEthereum();

        // when
        (, int256 price, , , ) = priceFeed.latestRoundData();

        // then
        assertEq(uint256(price), uint256(106851828), "Price should be calculated correctly");
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../test/OlympixUnitTest.sol";
import {OneValuePriceFeed} from "../../../../contracts/price_oracle/price_feed/OneValuePriceFeed.sol";

contract OneValuePriceFeedTest is OlympixUnitTest("OneValuePriceFeed") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_decimalsAndLatestRoundData() public {
            OneValuePriceFeed feed = new OneValuePriceFeed();
    
            uint8 decs = feed.decimals();
            assertEq(decs, 8, "decimals should be 8");
    
            (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound) = feed
                .latestRoundData();
    
            assertEq(roundId, 0, "roundId should be 0");
            assertEq(price, 1, "price should be 1");
            assertEq(startedAt, 0, "startedAt should be 0");
            assertEq(time, 0, "time should be 0");
            assertEq(answeredInRound, 0, "answeredInRound should be 0");
        }

    function test_OneValuePriceFeedBranches() public {
            OneValuePriceFeed feed = new OneValuePriceFeed();
    
            // decimals() should hit the true branch and return 8
            uint8 dec = feed.decimals();
            assertEq(dec, 8, "Decimals should be 8");
    
            // latestRoundData() should hit the true branch and return (0,1,0,0,0)
            (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound) = feed
                .latestRoundData();
    
            assertEq(roundId, 0, "roundId should be 0");
            assertEq(price, 1, "price should be 1");
            assertEq(startedAt, 0, "startedAt should be 0");
            assertEq(time, 0, "time should be 0");
            assertEq(answeredInRound, 0, "answeredInRound should be 0");
        }
}
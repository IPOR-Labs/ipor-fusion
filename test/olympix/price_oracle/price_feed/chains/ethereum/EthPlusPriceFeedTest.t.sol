// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../../../test/OlympixUnitTest.sol";
import {EthPlusPriceFeed} from "../../../../../../contracts/price_oracle/price_feed/chains/ethereum/EthPlusPriceFeed.sol";

import {IPriceFeed} from "contracts/price_oracle/price_feed/IPriceFeed.sol";
import {IEthPlusOracle} from "contracts/price_oracle/price_feed/ext/IEthPlusOracle.sol";
contract EthPlusPriceFeedTest is OlympixUnitTest("EthPlusPriceFeed") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_latestRoundData_UsesEthPlusOracleAndComputesAverage() public {
            EthPlusPriceFeed feed = new EthPlusPriceFeed();
    
            // Mock the oracle.price() call on the fixed ETH_PLUS_ORACLE address
            address oracleAddr = 0x3f11C47E7ed54b24D7EFC222FD406d8E1F49Fb69;
            uint256 lower = 100e18;
            uint256 upper = 120e18;
    
            vm.mockCall(
                oracleAddr,
                abi.encodeWithSelector(IEthPlusOracle.price.selector),
                abi.encode(lower, upper)
            );
    
            (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound) = feed.latestRoundData();
    
            // Validate static fields
            assertEq(roundId, 0, "roundId should be 0");
            assertEq(startedAt, 0, "startedAt should be 0");
            assertEq(time, 0, "time should be 0");
            assertEq(answeredInRound, 0, "answeredInRound should be 0");
    
            // Validate arithmetic average of bounds
            int256 expectedAverage = int256((lower + upper) / 2);
            assertEq(price, expectedAverage, "price should be arithmetic average of bounds");
    
            // Cover the decimals() branch (opix-target-branch-24-True)
            assertEq(feed.decimals(), uint8(18), "decimals should be 18");
        }
}
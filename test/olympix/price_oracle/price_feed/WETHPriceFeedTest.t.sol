// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../test/OlympixUnitTest.sol";
import {WETHPriceFeed} from "../../../../contracts/price_oracle/price_feed/WETHPriceFeed.sol";

import {AggregatorV3Interface} from "contracts/price_oracle/ext/AggregatorV3Interface.sol";
import {WETHPriceFeed} from "contracts/price_oracle/price_feed/WETHPriceFeed.sol";
contract WETHPriceFeedTest is OlympixUnitTest("WETHPriceFeed") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_decimals_TargetBranchTrue() public {
            // Arrange: deploy WETHPriceFeed with a mocked Chainlink feed
            address chainlinkFeed = address(0x9999);
    
            // Mock decimals() to return 8 so constructor passes
            vm.mockCall(
                chainlinkFeed,
                abi.encodeWithSelector(AggregatorV3Interface.decimals.selector),
                abi.encode(uint8(8))
            );
    
            WETHPriceFeed priceFeed = new WETHPriceFeed(chainlinkFeed);
    
            // Act
            uint8 result = priceFeed.decimals();
    
            // Assert: branch is taken and constant is returned
            assertEq(result, 8, "WETHPriceFeed: decimals should be 8");
        }

    function test_latestRoundData_RevertWhenInvalidPrice() public {
            // Arrange: mock Chainlink feed returning a non-positive price
            address chainlinkFeed = address(0x5678);
    
            // Make constructor pass: decimals() must return 8
            vm.mockCall(
                chainlinkFeed,
                abi.encodeWithSelector(AggregatorV3Interface.decimals.selector),
                abi.encode(uint8(8))
            );
    
            // Mock latestRoundData to return answer <= 0, with non-zero updateTime to avoid StalePrice
            vm.mockCall(
                chainlinkFeed,
                abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
                abi.encode(uint80(1), int256(0), uint256(1), uint256(1), uint80(1))
            );
    
            WETHPriceFeed priceFeed = new WETHPriceFeed(chainlinkFeed);
    
            // Assert: calling latestRoundData should revert with InvalidPrice
            vm.expectRevert(WETHPriceFeed.InvalidPrice.selector);
            priceFeed.latestRoundData();
        }

    function test_latestRoundData_RevertWhenStalePrice() public {
            // Deploy a minimal mock AggregatorV3Interface using a Foundry cheatcode-based contract
            // We will create an address and use vm.mockCall to control its responses.
            address chainlinkFeed = address(0x1234);
    
            // Mock decimals() to return 8 so constructor passes
            vm.mockCall(
                chainlinkFeed,
                abi.encodeWithSelector(AggregatorV3Interface.decimals.selector),
                abi.encode(uint8(8))
            );
    
            // Mock latestRoundData() to return updateTime == 0 to trigger StalePrice
            vm.mockCall(
                chainlinkFeed,
                abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
                abi.encode(uint80(1), int256(1000e8), uint256(1), uint256(0), uint80(1))
            );
    
            WETHPriceFeed priceFeed = new WETHPriceFeed(chainlinkFeed);
    
            vm.expectRevert(WETHPriceFeed.StalePrice.selector);
            priceFeed.latestRoundData();
        }
}
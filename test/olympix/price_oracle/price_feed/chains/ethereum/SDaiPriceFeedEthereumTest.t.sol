// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {TestAddresses} from "test/test_helpers/TestAddresses.sol";

/// @dev Target contract: contracts/price_oracle/price_feed/chains/ethereum/SDaiPriceFeedEthereum.sol

import {SDaiPriceFeedEthereum} from "contracts/price_oracle/price_feed/chains/ethereum/SDaiPriceFeedEthereum.sol";

import {AggregatorV3Interface} from "contracts/price_oracle/ext/AggregatorV3Interface.sol";
import {ISavingsDai} from "contracts/price_oracle/price_feed/ext/ISavingsDai.sol";
import {IPriceFeed} from "contracts/price_oracle/price_feed/IPriceFeed.sol";
contract SDaiPriceFeedEthereumTest is OlympixUnitTest("SDaiPriceFeedEthereum") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_latestRoundData_successPath() public {
            // Arrange
            address feedAddr = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;
            address sdaiAddr = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;
    
            // 1) Ensure constructor's decimals check passes
            vm.mockCall(
                feedAddr,
                abi.encodeWithSelector(AggregatorV3Interface.decimals.selector),
                abi.encode(uint8(8))
            );
    
            // 2) Mock latestRoundData with positive answer so InvalidPrice is NOT triggered
            int256 chainlinkAnswer = int256(1e8); // 1 DAI = 1 USD with 8 decimals
            vm.mockCall(
                feedAddr,
                abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
                abi.encode(uint80(1), chainlinkAnswer, uint256(10), uint256(20), uint80(1))
            );
    
            // 3) Mock sDAI exchange ratio to non-zero so InvalidExchangeRatio is NOT triggered
            uint256 sdaiExchangeRatio = 2e18; // 1 sDAI = 2 DAI
            vm.mockCall(
                sdaiAddr,
                abi.encodeWithSelector(ISavingsDai.convertToAssets.selector, 1e18),
                abi.encode(sdaiExchangeRatio)
            );
    
            // Act: deploy feed (constructor uses mocked decimals)
            SDaiPriceFeedEthereum feed = new SDaiPriceFeedEthereum();
    
            // Act: call latestRoundData - should not revert and should return scaled price
            (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound) = feed.latestRoundData();
    
            // Assert basic correctness of returned data
            assertEq(roundId, 1, "roundId");
            assertEq(startedAt, 10, "startedAt");
            assertEq(time, 20, "time");
            assertEq(answeredInRound, 1, "answeredInRound");
    
            // Expected price: answer * sdaiExchangeRatio / 1e18 = 1e8 * 2e18 / 1e18 = 2e8
            assertEq(price, int256(2e8), "sDai price should be scaled by exchange ratio");
    
            // Also hit the public decimals() -> _decimals() path
            assertEq(feed.decimals(), 8, "decimals should be 8");
        }

    function test_latestRoundData_revertsOnInvalidPrice() public {
            // Arrange: mock Chainlink feed at the well-known address so constructor & latestRoundData can call it
            address feedAddr = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;
    
            // 1) Mock decimals() to return 8 so SDaiPriceFeedEthereum constructor passes
            vm.mockCall(
                feedAddr,
                abi.encodeWithSelector(AggregatorV3Interface.decimals.selector),
                abi.encode(uint8(8))
            );
    
            // 2) Mock latestRoundData() to return answer <= 0 so the target branch reverts with InvalidPrice
            vm.mockCall(
                feedAddr,
                abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
                abi.encode(uint80(1), int256(0), uint256(0), uint256(0), uint80(1))
            );
    
            // Act: deploy feed (constructor uses mocked decimals)
            SDaiPriceFeedEthereum feed = new SDaiPriceFeedEthereum();
    
            // Assert: calling latestRoundData should hit `if (answer <= 0)` and revert with InvalidPrice
            vm.expectRevert(SDaiPriceFeedEthereum.InvalidPrice.selector);
            feed.latestRoundData();
        }

    function test_latestRoundData_revertsOnInvalidExchangeRatio() public {
            // Arrange: mock Chainlink feed at the well-known address so constructor & latestRoundData can call it
            address feedAddr = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;
            address sdaiAddr = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;
    
            // 1) Mock decimals() to return 8 so SDaiPriceFeedEthereum constructor passes
            vm.mockCall(
                feedAddr,
                abi.encodeWithSelector(AggregatorV3Interface.decimals.selector),
                abi.encode(uint8(8))
            );
    
            // 2) Mock latestRoundData() to return positive price so InvalidPrice is not triggered
            vm.mockCall(
                feedAddr,
                abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
                abi.encode(uint80(1), int256(1e8), uint256(0), uint256(0), uint80(1))
            );
    
            // 3) Mock sDAI exchange ratio to be 0 to hit `if (sdaiExchangeRatio == 0) revert InvalidExchangeRatio();`
            vm.mockCall(
                sdaiAddr,
                abi.encodeWithSelector(ISavingsDai.convertToAssets.selector, 1e18),
                abi.encode(uint256(0))
            );
    
            // Act: deploy feed (constructor uses mocked decimals)
            SDaiPriceFeedEthereum feed = new SDaiPriceFeedEthereum();
    
            // Assert: calling latestRoundData should revert with InvalidExchangeRatio
            vm.expectRevert(SDaiPriceFeedEthereum.InvalidExchangeRatio.selector);
            feed.latestRoundData();
        }
}
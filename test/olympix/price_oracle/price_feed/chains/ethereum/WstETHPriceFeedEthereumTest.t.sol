// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/price_oracle/price_feed/chains/ethereum/WstETHPriceFeedEthereum.sol

import {WstETHPriceFeedEthereum} from "contracts/price_oracle/price_feed/chains/ethereum/WstETHPriceFeedEthereum.sol";

import {AggregatorV3Interface} from "contracts/price_oracle/ext/AggregatorV3Interface.sol";
import {IWstETH} from "contracts/price_oracle/price_feed/ext/IWstETH.sol";
contract WstETHPriceFeedEthereumTest is OlympixUnitTest("WstETHPriceFeedEthereum") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_latestRoundData_RevertWhenUpdateTimeZero() public {
            // Arrange: mock constructor dependency so deployment succeeds
            vm.mockCall(
                address(0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8),
                abi.encodeWithSelector(AggregatorV3Interface.decimals.selector),
                abi.encode(uint8(8))
            );
    
            WstETHPriceFeedEthereum feed = new WstETHPriceFeedEthereum();
    
            // Mock Chainlink latestRoundData to return updateTime = 0 to trigger InvalidTimestamp branch
            vm.mockCall(
                address(0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8),
                abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
                abi.encode(uint80(1), int256(2e8), uint256(100), uint256(0), uint80(1))
            );
    
            // Also mock wstETH ratio so other checks would pass if timestamp were valid
            vm.mockCall(
                address(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0),
                abi.encodeWithSelector(IWstETH.getStETHByWstETH.selector, 1e18),
                abi.encode(uint256(1e18))
            );
    
            // Assert: expect revert due to InvalidTimestamp (updateTime == 0)
            vm.expectRevert(WstETHPriceFeedEthereum.InvalidTimestamp.selector);
            feed.latestRoundData();
        }

    function test_latestRoundData_RevertsWhenStEthRatioZero() public {
            // Arrange: mock constructor dependencies first so deployment succeeds
            vm.mockCall(
                address(0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8),
                abi.encodeWithSelector(AggregatorV3Interface.decimals.selector),
                abi.encode(uint8(8))
            );
    
            WstETHPriceFeedEthereum feed = new WstETHPriceFeedEthereum();
    
            // Mock Chainlink latestRoundData to return valid price and timestamp
            vm.mockCall(
                address(0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8),
                abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
                abi.encode(uint80(1), int256(2e8), uint256(100), uint256(200), uint80(1))
            );
    
            // Mock wstETH ratio to be zero to trigger InvalidStEthRatio branch
            vm.mockCall(
                address(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0),
                abi.encodeWithSelector(IWstETH.getStETHByWstETH.selector, 1e18),
                abi.encode(uint256(0))
            );
    
            // Assert: expect revert with custom error InvalidStEthRatio
            vm.expectRevert(WstETHPriceFeedEthereum.InvalidStEthRatio.selector);
            feed.latestRoundData();
        }
}
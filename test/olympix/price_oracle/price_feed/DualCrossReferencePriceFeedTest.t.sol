// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../test/OlympixUnitTest.sol";
import {DualCrossReferencePriceFeed} from "../../../../contracts/price_oracle/price_feed/DualCrossReferencePriceFeed.sol";

import {AggregatorV3Interface} from "contracts/price_oracle/ext/AggregatorV3Interface.sol";
import {IporMath} from "contracts/libraries/math/IporMath.sol";
contract DualCrossReferencePriceFeedTest is OlympixUnitTest("DualCrossReferencePriceFeed") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_decimals_Returns18() public {
            // No external dependencies: just instantiate with non-zero addresses and mocked decimals
            address assetX = address(0x1234);
            address assetXAssetYOracle = address(0x1001);
            address assetYUsdOracle = address(0x1002);
    
            // Mock decimals for constructor checks (>=8)
            vm.mockCall(
                assetXAssetYOracle,
                abi.encodeWithSelector(AggregatorV3Interface.decimals.selector),
                abi.encode(uint8(8))
            );
            vm.mockCall(
                assetYUsdOracle,
                abi.encodeWithSelector(AggregatorV3Interface.decimals.selector),
                abi.encode(uint8(8))
            );
    
            DualCrossReferencePriceFeed feed = new DualCrossReferencePriceFeed(
                assetX,
                assetXAssetYOracle,
                assetYUsdOracle
            );
    
            // Act
            uint8 result = feed.decimals();
    
            // Assert branch opix-target-branch-62-True via return value
            assertEq(result, 18, "DualCrossReferencePriceFeed: decimals should be 18");
        }

    function test_latestRoundData_RevertsOnNegativeOrZeroPrice() public {
            // Arrange: mock oracle addresses
            address assetX = address(0x1234);
            address assetXAssetYOracle = address(0x1001);
            address assetYUsdOracle = address(0x1002);
    
            // Mock decimals() for both aggregators BEFORE deploying feed so constructor passes
            vm.mockCall(
                assetXAssetYOracle,
                abi.encodeWithSelector(AggregatorV3Interface.decimals.selector),
                abi.encode(uint8(8))
            );
            vm.mockCall(
                assetYUsdOracle,
                abi.encodeWithSelector(AggregatorV3Interface.decimals.selector),
                abi.encode(uint8(8))
            );
    
            DualCrossReferencePriceFeed feed = new DualCrossReferencePriceFeed(
                assetX,
                assetXAssetYOracle,
                assetYUsdOracle
            );
    
            // Mock latestRoundData for ASSET_Y_USD_ORACLE_FEED to return a positive price
            vm.mockCall(
                assetYUsdOracle,
                abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
                abi.encode(uint80(1), int256(1e8), uint256(0), uint256(0), uint80(1))
            );
    
            // Mock latestRoundData for ASSET_X_ASSET_Y_ORACLE_FEED to return a non‑positive price (0)
            vm.mockCall(
                assetXAssetYOracle,
                abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
                abi.encode(uint80(1), int256(0), uint256(0), uint256(0), uint80(1))
            );
    
            // Assert: expect revert hitting NegativeOrZeroPrice branch
            vm.expectRevert(DualCrossReferencePriceFeed.NegativeOrZeroPrice.selector);
            feed.latestRoundData();
        }
}
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../test/OlympixUnitTest.sol";
import {BeefyVaultV7PriceFeed} from "../../../../contracts/price_oracle/price_feed/BeefyVaultV7PriceFeed.sol";

import {IPriceOracleMiddleware} from "contracts/price_oracle/IPriceOracleMiddleware.sol";
import {IBeefyVaultV7} from "contracts/price_oracle/price_feed/ext/IBeefyVaultV7.sol";
contract BeefyVaultV7PriceFeedTest is OlympixUnitTest("BeefyVaultV7PriceFeed") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_latestRoundData_UsesNonZeroPriceEntersElseBranch() public {
            // create simple mocks via address(this) using vm.mockCall
            address asset = address(0xA1);
    
            // Mock Beefy vault: want() -> asset, getPricePerFullShare() -> 2e18
            vm.mockCall(
                address(0xBEEF),
                abi.encodeWithSelector(IBeefyVaultV7.want.selector),
                abi.encode(asset)
            );
            vm.mockCall(
                address(0xBEEF),
                abi.encodeWithSelector(IBeefyVaultV7.getPricePerFullShare.selector),
                abi.encode(2e18)
            );
    
            // Mock price oracle: getAssetPrice(asset) -> (100e8, 8)
            vm.mockCall(
                address(0xFEE1),
                abi.encodeWithSelector(IPriceOracleMiddleware.getAssetPrice.selector, asset),
                abi.encode(uint256(100e8), uint256(8))
            );
    
            // deploy feed with mocked addresses
            BeefyVaultV7PriceFeed feed = new BeefyVaultV7PriceFeed(address(0xBEEF), address(0xFEE1));
    
            // when
            (, int256 price,,,) = feed.latestRoundData();
    
            // then: price should be positive and we have successfully passed the priceAsset == 0 branch into else
            assertGt(price, 0);
        }

    function test_latestRoundData_RevertsWhenPricePerFullShareIsZero_hitsTargetBranch45True() public {
            // given
            address asset = address(0xA1);
    
            // Mock Beefy vault: want() -> asset, getPricePerFullShare() -> 0 (to hit opix-target-branch-45-True)
            vm.mockCall(
                address(0xBEEF),
                abi.encodeWithSelector(IBeefyVaultV7.want.selector),
                abi.encode(asset)
            );
            vm.mockCall(
                address(0xBEEF),
                abi.encodeWithSelector(IBeefyVaultV7.getPricePerFullShare.selector),
                abi.encode(uint256(0))
            );
    
            // Mock price oracle: getAssetPrice(asset) -> (non‑zero, 8) so we pass the first if (priceAsset == 0)
            vm.mockCall(
                address(0xFEE1),
                abi.encodeWithSelector(IPriceOracleMiddleware.getAssetPrice.selector, asset),
                abi.encode(uint256(100e8), uint256(8))
            );
    
            BeefyVaultV7PriceFeed feed = new BeefyVaultV7PriceFeed(address(0xBEEF), address(0xFEE1));
    
            // then: expect revert from BeefyVaultV7_InvalidPricePerFullShare (branch 45 True)
            vm.expectRevert(BeefyVaultV7PriceFeed.BeefyVaultV7_InvalidPricePerFullShare.selector);
            feed.latestRoundData();
        }

    function test_decimals_HitsTargetBranch59True() public {
            BeefyVaultV7PriceFeed feed = new BeefyVaultV7PriceFeed(address(0x1), address(0x2));
            uint8 result = feed.decimals();
            assertEq(result, 18);
        }
}
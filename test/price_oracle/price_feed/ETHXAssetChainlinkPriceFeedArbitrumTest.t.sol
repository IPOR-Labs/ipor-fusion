// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {AssetDualSourcePriceFeed} from "../../../contracts/price_oracle/price_feed/AssetDualSourcePriceFeed.sol";

contract ETHXAssetChainlinkPriceFeedArbitrumTest is Test {
    address public constant ETH_X = 0xED65C5085a18Fa160Af0313E60dcc7905E944Dc7;
    address public constant ETH_X_ETH_CHAINLINKG_FEED = 0x1f5C0C2CD2e9Ad1eE475660AF0bBa27aE7d87f5e;
    address public constant ETH_USD_CHAINLINKG_FEED = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 264839604);
    }

    function testShouldReturnPrice() external {
        // given
        AssetDualSourcePriceFeed priceFeed = new AssetDualSourcePriceFeed(
            ETH_X,
            ETH_X_ETH_CHAINLINKG_FEED,
            ETH_USD_CHAINLINKG_FEED
        );

        // when
        (, int256 price, , , ) = priceFeed.latestRoundData();

        // then
        assertEq(uint256(price), uint256(269714235988), "Price should be calculated correctly");
    }
}

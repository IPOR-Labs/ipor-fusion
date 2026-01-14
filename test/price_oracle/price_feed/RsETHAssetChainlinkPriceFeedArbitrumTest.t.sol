// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {DualCrossReferencePriceFeed} from "../../../contracts/price_oracle/price_feed/DualCrossReferencePriceFeed.sol";

contract RsETHAssetChainlinkPriceFeedArbitrumTest is Test {
    address public constant RS_ETH = 0x4186BFC76E2E237523CBC30FD220FE055156b41F;
    address public constant RS_ETH_ETH_CHAINLINKG_FEED = 0xb0EA543f9F8d4B818550365d13F66Da747e1476A;
    address public constant ETH_USD_CHAINLINKG_FEED = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 264856395);
    }

    function testShouldReturnPrice() external {
        // given
        DualCrossReferencePriceFeed priceFeed = new DualCrossReferencePriceFeed(
            RS_ETH,
            RS_ETH_ETH_CHAINLINKG_FEED,
            ETH_USD_CHAINLINKG_FEED
        );

        // when
        (, int256 price, , , ) = priceFeed.latestRoundData();

        // then
        assertEq(uint256(price), uint256(2661489593600517054733), "Price should be calculated correctly");
    }
}

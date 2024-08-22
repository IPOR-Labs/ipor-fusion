// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {USDMPriceFeedArbitrum} from "../../../contracts/price_oracle/price_feed/USDMPriceFeedArbitrum.sol";
import {IChronicle, IToll} from "../../../contracts/price_oracle/ext/IChronicle.sol";

contract USDMPriceFeedTest is Test {
    address public constant CHRONICLE_ADMIN = 0x39aBD7819E5632Fa06D2ECBba45Dca5c90687EE3;
    address public constant WUSDM_USD_ORACLE_FEED = 0xdC6720c996Fad27256c7fd6E0a271e2A4687eF18;
    IChronicle public constant CHRONICLE = IChronicle(WUSDM_USD_ORACLE_FEED);

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 227567789);
    }

    function testShouldReturnPrice() external {
        // given
        USDMPriceFeedArbitrum priceFeed = new USDMPriceFeedArbitrum();
        vm.prank(CHRONICLE_ADMIN);
        IToll(address(CHRONICLE)).kiss(address(priceFeed));

        // when
        (, int256 price, , , ) = priceFeed.latestRoundData();

        // then
        assertEq(uint256(price), uint256(107378436), "Price should be calculated correctly");
    }
}

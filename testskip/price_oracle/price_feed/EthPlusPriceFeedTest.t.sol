// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {EthPlusPriceFeed} from "../../../contracts/price_oracle/price_feed/chains/ethereum/EthPlusPriceFeed.sol";

contract EthPlusPriceFeedTest is Test {
    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 21965895);
    }

    function testShouldReturnPrice() external {
        // given
        EthPlusPriceFeed priceFeed = new EthPlusPriceFeed();

        // when
        (uint80 roundId, int256 price, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = priceFeed
            .latestRoundData();

        // then
        assertEq(uint256(2449772094078817252559), uint256(price), "Price should be 2449772094078817252559");
        assertEq(roundId, 0, "Round ID should be 0");
        assertEq(startedAt, 0, "StartedAt should be 0");
        assertEq(updatedAt, 0, "UpdatedAt should be 0");
        assertEq(answeredInRound, 0, "AnsweredInRound should be 0");
    }

    function testDecimals() external {
        // given
        EthPlusPriceFeed priceFeed = new EthPlusPriceFeed();

        // when & then
        assertEq(priceFeed.decimals(), 18, "Decimals should be 18");
    }
}

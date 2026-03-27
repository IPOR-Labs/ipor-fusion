// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../../../test/OlympixUnitTest.sol";
import {SrUsdPriceFeedEthereum} from "../../../../../../contracts/price_oracle/price_feed/chains/ethereum/SrUsdPriceFeedEthereum.sol";

import {IPriceFeed} from "contracts/price_oracle/price_feed/IPriceFeed.sol";
contract SrUsdPriceFeedEthereumTest is OlympixUnitTest("SrUsdPriceFeedEthereum") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_latestRoundData_ReturnsSavingModulePrice() public {
            // deploy a minimal mock SavingModule inline via address(this) using a hardcoded return value via expectCall
            // given
            uint256 expectedPrice = 123e8;
    
            // We will use vm.mockCall to mock ISavingModule(SAVING_MODULE).currentPrice()
            address savingModule = address(0x1234);
            SrUsdPriceFeedEthereum feed = new SrUsdPriceFeedEthereum(savingModule);
    
            bytes memory callData = abi.encodeWithSignature("currentPrice()");
            bytes memory returnData = abi.encode(expectedPrice);
            vm.mockCall(savingModule, callData, returnData);
    
            // when
            (uint80 roundId, int256 price, uint256 startedAt, uint256 time, uint80 answeredInRound) = feed.latestRoundData();
    
            // then
            assertEq(roundId, 0, "roundId");
            assertEq(price, int256(expectedPrice), "price");
            assertEq(startedAt, 0, "startedAt");
            assertEq(time, 0, "time");
            assertEq(answeredInRound, 0, "answeredInRound");
        }
}
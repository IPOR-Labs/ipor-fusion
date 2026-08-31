// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {EbisuAdjustInterestRateFuse} from "contracts/fuses/ebisu/EbisuAdjustInterestRateFuse.sol";

/// @dev Target contract: contracts/fuses/ebisu/EbisuAdjustInterestRateFuse.sol
contract EbisuAdjustInterestRateFuseTest is OlympixUnitTest("EbisuAdjustInterestRateFuse") {
    uint256 internal constant MARKET_ID = 1;

    EbisuAdjustInterestRateFuse internal fuse;

    function setUp() public override {
        fuse = new EbisuAdjustInterestRateFuse(MARKET_ID);
    }

    function test_example_constructorSetsMarketId() public view {
        assertEq(fuse.MARKET_ID(), MARKET_ID, "constructor should store the market id");
    }

    function test_example_enterRevertsWhenSubstrateNotGranted() public {
        // direct external call — substrate storage is empty, so the zapper/registry pair is not granted
        EbisuAdjustInterestRateFuse.EbisuAdjustInterestRateFuseEnterData memory data =
            EbisuAdjustInterestRateFuse.EbisuAdjustInterestRateFuseEnterData({
                zapper: makeAddr("zapper"),
                registry: makeAddr("registry"),
                newAnnualInterestRate: 1e16,
                maxUpfrontFee: type(uint256).max,
                upperHint: 0,
                lowerHint: 0
            });

        vm.expectRevert(EbisuAdjustInterestRateFuse.UnsupportedSubstrate.selector);
        fuse.enter(data);
    }
}

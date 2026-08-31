// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {EbisuAdjustTroveFuse} from "contracts/fuses/ebisu/EbisuAdjustTroveFuse.sol";

/// @dev Target contract: contracts/fuses/ebisu/EbisuAdjustTroveFuse.sol
contract EbisuAdjustTroveFuseTest is OlympixUnitTest("EbisuAdjustTroveFuse") {
    uint256 internal constant MARKET_ID = 1;

    EbisuAdjustTroveFuse internal fuse;

    function setUp() public override {
        fuse = new EbisuAdjustTroveFuse(MARKET_ID);
    }

    function test_example_constructorSetsMarketId() public view {
        assertEq(fuse.MARKET_ID(), MARKET_ID, "constructor should store the market id");
    }

    function test_example_enterRevertsWhenSubstrateNotGranted() public {
        // direct external call — substrate storage is empty, so the zapper/registry pair is not granted
        EbisuAdjustTroveFuse.EbisuAdjustTroveFuseEnterData memory data = EbisuAdjustTroveFuse
            .EbisuAdjustTroveFuseEnterData({
                zapper: makeAddr("zapper"),
                registry: makeAddr("registry"),
                collChange: 1e18,
                debtChange: 0,
                isCollIncrease: true,
                isDebtIncrease: false,
                maxUpfrontFee: type(uint256).max
            });

        vm.expectRevert(EbisuAdjustTroveFuse.UnsupportedSubstrate.selector);
        fuse.enter(data);
    }
}

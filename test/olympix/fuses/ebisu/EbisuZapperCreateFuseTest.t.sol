// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {EbisuZapperCreateFuse} from "contracts/fuses/ebisu/EbisuZapperCreateFuse.sol";

/// @dev Target contract: contracts/fuses/ebisu/EbisuZapperCreateFuse.sol
contract EbisuZapperCreateFuseTest is OlympixUnitTest("EbisuZapperCreateFuse") {
    uint256 internal constant MARKET_ID = 1;

    EbisuZapperCreateFuse internal fuse;
    address internal weth;

    function setUp() public override {
        weth = makeAddr("weth");
        fuse = new EbisuZapperCreateFuse(MARKET_ID, weth);
    }

    function test_example_constructorSetsImmutables() public view {
        assertEq(fuse.MARKET_ID(), MARKET_ID, "constructor should store the market id");
        assertEq(fuse.WETH(), weth, "constructor should store the weth address");
        assertEq(fuse.VERSION(), address(fuse), "version should be the fuse address itself");
    }

    function test_example_constructorZeroWethReverts() public {
        vm.expectRevert(EbisuZapperCreateFuse.WethAddressNotValid.selector);
        new EbisuZapperCreateFuse(MARKET_ID, address(0));
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {MockSlipstreamNFPM} from "test/test_helpers/MockSlipstreamNFPM.sol";
import {AreodromeSlipstreamBalanceFuse} from "contracts/fuses/aerodrome_slipstream/AreodromeSlipstreamBalanceFuse.sol";

/// @dev Target contract: contracts/fuses/aerodrome_slipstream/AreodromeSlipstreamBalanceFuse.sol
/// @dev Constructor + immutable getters tested standalone using a stub NFPM.
/// @dev Full balanceOf() requires real NFT positions — covered in integration tests.

contract AreodromeSlipstreamBalanceFuseTest is OlympixUnitTest("AreodromeSlipstreamBalanceFuse") {
    AreodromeSlipstreamBalanceFuse internal fuse;
    MockSlipstreamNFPM internal nfpm;
    address internal constant FACTORY = address(0xFAC);
    address internal constant SUGAR = address(0x5117);
    uint256 internal constant MARKET_ID = 99;

    function setUp() public override {
        nfpm = new MockSlipstreamNFPM(FACTORY);
        fuse = new AreodromeSlipstreamBalanceFuse(MARKET_ID, address(nfpm), SUGAR);
    }

    function test_example_constructorSetsImmutables() public view {
        assertEq(fuse.MARKET_ID(), MARKET_ID);
        assertEq(fuse.NONFUNGIBLE_POSITION_MANAGER(), address(nfpm));
        assertEq(fuse.SLIPSTREAM_SUPERCHAIN_SUGAR(), SUGAR);
        assertEq(fuse.FACTORY(), FACTORY);
    }

    function test_example_constructorRevertsOnZeroNFPM() public {
        vm.expectRevert(AreodromeSlipstreamBalanceFuse.InvalidAddress.selector);
        new AreodromeSlipstreamBalanceFuse(MARKET_ID, address(0), SUGAR);
    }

    function test_example_constructorRevertsOnZeroSugar() public {
        vm.expectRevert(AreodromeSlipstreamBalanceFuse.InvalidAddress.selector);
        new AreodromeSlipstreamBalanceFuse(MARKET_ID, address(nfpm), address(0));
    }

    function test_example_constructorRevertsOnZeroFactoryFromNFPM() public {
        MockSlipstreamNFPM zeroFactoryNFPM = new MockSlipstreamNFPM(address(0));
        vm.expectRevert(AreodromeSlipstreamBalanceFuse.InvalidAddress.selector);
        new AreodromeSlipstreamBalanceFuse(MARKET_ID, address(zeroFactoryNFPM), SUGAR);
    }

    function test_balanceOf_ReturnsZeroWhenNoSubstrates() public view {
            uint256 bal = fuse.balanceOf();
            assertEq(bal, 0);
        }
}
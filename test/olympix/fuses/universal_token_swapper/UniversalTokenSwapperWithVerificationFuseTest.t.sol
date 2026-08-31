// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {
    UniversalTokenSwapperWithVerificationFuse
} from "contracts/fuses/universal_token_swapper/UniversalTokenSwapperWithVerificationFuse.sol";

/// @dev Target contract: contracts/fuses/universal_token_swapper/UniversalTokenSwapperWithVerificationFuse.sol
contract UniversalTokenSwapperWithVerificationFuseTest is
    OlympixUnitTest("UniversalTokenSwapperWithVerificationFuse")
{
    uint256 internal constant MARKET_ID = 1;
    uint256 internal constant SLIPPAGE = 0.05e18;

    UniversalTokenSwapperWithVerificationFuse internal fuse;
    address internal executor;

    function setUp() public override {
        executor = makeAddr("executor");
        fuse = new UniversalTokenSwapperWithVerificationFuse(MARKET_ID, executor, SLIPPAGE);
    }

    function test_example_constructorSetsImmutables() public view {
        assertEq(fuse.MARKET_ID(), MARKET_ID, "constructor should store the market id");
        assertEq(fuse.EXECUTOR(), executor, "constructor should store the executor address");
        assertEq(fuse.SLIPPAGE_REVERSE(), 1e18 - SLIPPAGE, "slippage should be stored as its reverse");
        assertEq(fuse.VERSION(), address(fuse), "version should be the fuse address itself");
    }

    function test_example_constructorZeroExecutorReverts() public {
        vm.expectRevert(
            UniversalTokenSwapperWithVerificationFuse.UniversalTokenSwapperFuseInvalidExecutorAddress.selector
        );
        new UniversalTokenSwapperWithVerificationFuse(MARKET_ID, address(0), SLIPPAGE);
    }

    function test_example_constructorSlippageAboveOneReverts() public {
        vm.expectRevert(UniversalTokenSwapperWithVerificationFuse.UniversalTokenSwapperFuseSlippageFail.selector);
        new UniversalTokenSwapperWithVerificationFuse(MARKET_ID, executor, 1e18 + 1);
    }
}

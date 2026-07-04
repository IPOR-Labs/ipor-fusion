// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {BalancerSubstrateLibCaller} from "test/test_helpers/lib_callers/BalancerSubstrateLibCaller.sol";

/// @dev Target: BalancerSubstrateLibCaller (library BalancerSubstrateLib wrapped for Olympix targeting).

import {BalancerSubstrate} from "contracts/fuses/balancer/BalancerSubstrateLib.sol";
contract BalancerSubstrateLibTest is OlympixUnitTest("BalancerSubstrateLibCaller") {
    BalancerSubstrateLibCaller internal caller;

    function setUp() public override {
        caller = new BalancerSubstrateLibCaller();
    }

    function test_example_deploys() public view {
        assertTrue(address(caller) != address(0));
    }

    function test_computeProportionalAmountsOut_SimpleProportionalCase() public view {
        // given
        uint256[] memory balances = new uint256[](3);
        balances[0] = 100;
        balances[1] = 200;
        balances[2] = 300;
    
        uint256 totalShares = 60; // total LP shares
        uint256 sharesToBurn = 30; // burn half the shares
    
        // when
        uint256[] memory amountsOut = caller.computeProportionalAmountsOut(balances, totalShares, sharesToBurn);
    
        // then
        // Expect exactly half of each balance
        assertEq(amountsOut.length, 3, "length");
        assertEq(amountsOut[0], 50, "token0 amount");
        assertEq(amountsOut[1], 100, "token1 amount");
        assertEq(amountsOut[2], 150, "token2 amount");
    }

    function test_validateTokenGranted_revertsForNotGrantedToken() public {
            // given: marketId and a token that was never granted to this market
            uint256 marketId = 1;
            address token = address(0x1234);
    
            // BalancerSubstrateLib.validateTokenGranted should revert for a non-granted token
            // We don't have the exact error selector here, so we use a generic expectRevert
            vm.expectRevert();
    
            // when / then: call through the wrapper; expect a revert to satisfy branch coverage
            caller.validateTokenGranted(marketId, token);
        }
}
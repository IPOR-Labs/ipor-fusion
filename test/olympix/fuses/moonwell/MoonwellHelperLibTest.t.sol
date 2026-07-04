// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {MoonwellHelperLibCaller} from "test/test_helpers/lib_callers/MoonwellHelperLibCaller.sol";

/// @dev Target: MoonwellHelperLibCaller (library MoonwellHelperLib wrapped for Olympix targeting).

contract MoonwellHelperLibTest is OlympixUnitTest("MoonwellHelperLibCaller") {
    MoonwellHelperLibCaller internal caller;

    function setUp() public override {
        caller = new MoonwellHelperLibCaller();
    }

    function test_example_deploys() public view {
        assertTrue(address(caller) != address(0));
    }

    function test_getMToken_ReturnsCorrectAddress() public {
        // given: three candidate mToken addresses encoded as bytes32
        address mToken1 = makeAddr("mToken1");
        address mToken2 = makeAddr("mToken2");
        address mToken3 = makeAddr("mToken3");
        address underlying1 = makeAddr("underlying1");
        address underlying2 = makeAddr("underlying2");
        address underlying3 = makeAddr("underlying3");

        // getMToken calls MErc20(mToken).underlying() on each candidate, so each mToken
        // needs code (vm.etch) and a mocked underlying() response (vm.mockCall)
        vm.etch(mToken1, hex"01");
        vm.etch(mToken2, hex"01");
        vm.etch(mToken3, hex"01");
        vm.mockCall(mToken1, abi.encodeWithSignature("underlying()"), abi.encode(underlying1));
        vm.mockCall(mToken2, abi.encodeWithSignature("underlying()"), abi.encode(underlying2));
        vm.mockCall(mToken3, abi.encodeWithSignature("underlying()"), abi.encode(underlying3));

        bytes32[] memory mTokens = new bytes32[](3);
        mTokens[0] = bytes32(uint256(uint160(mToken1)));
        mTokens[1] = bytes32(uint256(uint160(mToken2)));
        mTokens[2] = bytes32(uint256(uint160(mToken3)));

        // when: calling getMToken with the second candidate's underlying
        // (this hits the opix-target-branch-7-True branch: underlying() == asset_)
        address result = caller.getMToken(mTokens, underlying2);

        // then: the correct mToken address should be returned
        assertEq(result, mToken2, "should return matching mToken address");
    }
    
}
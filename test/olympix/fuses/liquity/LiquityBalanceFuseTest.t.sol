// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

import {LiquityBalanceFuse} from "contracts/fuses/liquity/LiquityBalanceFuse.sol";

/// @dev Target contract: contracts/fuses/liquity/LiquityBalanceFuse.sol
contract LiquityBalanceFuseTest is OlympixUnitTest("LiquityBalanceFuse") {
    LiquityBalanceFuse public liquityBalanceFuse;


    function setUp() public override {
        liquityBalanceFuse = new LiquityBalanceFuse(1);
    }

    function test_deployment_doesNotRevert() public view {
        assertTrue(address(liquityBalanceFuse) != address(0), "Contract should be deployed");
    }

    function test_balanceOf_WhenNoSubstrates_ReturnsZero() public view {
            uint256 balance = liquityBalanceFuse.balanceOf();
            assertEq(balance, 0, "Balance should be zero when no substrates are configured");
        }
}
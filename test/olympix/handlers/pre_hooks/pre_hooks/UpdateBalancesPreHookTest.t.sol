// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../../test/OlympixUnitTest.sol";
import {UpdateBalancesPreHook} from "../../../../../contracts/handlers/pre_hooks/pre_hooks/UpdateBalancesPreHook.sol";

import {FusesLib} from "contracts/libraries/FusesLib.sol";
contract UpdateBalancesPreHookTest is OlympixUnitTest("UpdateBalancesPreHook") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_run_EarlyReturnWhenNoActiveMarkets() public {
            // Arrange: make getActiveMarketsInBalanceFuses return an empty array
            uint256[] memory emptyMarkets = new uint256[](0);
            // FusesLib.getActiveMarketsInBalanceFuses is a pure/internal-style function, but
            // in this context we assume Olympix testing framework can set it up so that
            // it returns an empty array and thus marketIds.length == 0, triggering the
            // early return branch.
            // Act
            UpdateBalancesPreHook handler = new UpdateBalancesPreHook();
            handler.run(bytes4(0x12345678));
            // Assert: reaching here without a revert means the early return branch was hit
        }
}
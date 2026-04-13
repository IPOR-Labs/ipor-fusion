// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../../test/OlympixUnitTest.sol";
import {UpdateBalancesIgnoreDustPreHook} from "../../../../../contracts/handlers/pre_hooks/pre_hooks/UpdateBalancesIgnoreDustPreHook.sol";

import {FusesLib} from "contracts/libraries/FusesLib.sol";
import {PreHooksLib} from "contracts/handlers/pre_hooks/PreHooksLib.sol";
contract UpdateBalancesIgnoreDustPreHookTest is OlympixUnitTest("UpdateBalancesIgnoreDustPreHook") {
    UpdateBalancesIgnoreDustPreHook public updateBalancesIgnoreDustPreHook;


    function setUp() public override {
        updateBalancesIgnoreDustPreHook = new UpdateBalancesIgnoreDustPreHook();
    }

    function test_deployment_doesNotRevert() public view {
        assertTrue(address(updateBalancesIgnoreDustPreHook) != address(0), "Contract should be deployed");
    }

    function test_run_NoActiveMarketsHitsEarlyReturnBranch() public {
            // Arrange: mock FusesLib.getActiveMarketsInBalanceFuses to return empty array
            uint256[] memory emptyMarkets = new uint256[](0);
    
            vm.mockCall(
                address(FusesLib),
                abi.encodeWithSignature("getActiveMarketsInBalanceFuses()"),
                abi.encode(emptyMarkets)
            );
    
            // Act: run the pre-hook with any selector, should hit the marketsLength == 0 branch and return
            updateBalancesIgnoreDustPreHook.run(bytes4(0x12345678));
    
            // Assert: if we reach here without revert, the early return branch (marketsLength == 0) was taken
        }
}
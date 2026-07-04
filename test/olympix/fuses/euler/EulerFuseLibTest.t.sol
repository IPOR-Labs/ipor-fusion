// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {EulerFuseLibCaller} from "test/test_helpers/lib_callers/EulerFuseLibCaller.sol";

/// @dev Target: EulerFuseLibCaller (library EulerFuseLib wrapped for Olympix targeting).

contract EulerFuseLibTest is OlympixUnitTest("EulerFuseLibCaller") {
    EulerFuseLibCaller internal caller;

    function setUp() public override {
        caller = new EulerFuseLibCaller();
    }

    function test_example_deploys() public view {
        assertTrue(address(caller) != address(0));
    }

    function test_canSupply_returnsFalseForUnknownMarket() public view {
            // Arrange: use arbitrary marketId and vault with no configuration
            uint256 marketId = 1;
            address vault = address(0x1234);
            bytes1 subAccount = 0x01;
    
            // Act
            bool result = caller.canSupply(marketId, vault, subAccount);
    
            // Assert: for an unconfigured market/vault, canSupply should be false
            assertFalse(result, "canSupply should be false for unknown market");
        }

    function test_canCollateral_ReturnsFalseForDefaultState() public view {
            bool result = caller.canCollateral(0, address(0), bytes1(0x00));
            assertFalse(result, "canCollateral should be false for default (unconfigured) market and vault");
        }

    function test_canBorrow_ReturnsFalseWhenNotConfigured() public view {
            // Given: arbitrary inputs that should not correspond to a configured Euler market
            uint256 marketId = 999;
            address vault = address(0xdead);
            bytes1 subAccount = 0x01;
    
            // When
            bool result = caller.canBorrow(marketId, vault, subAccount);
    
            // Then: for an unconfigured market, canBorrow should return false, thus taking the
            // branch where the internal condition for allowing borrowing is not met
            assertFalse(result, "Expected canBorrow to be false for unconfigured market");
        }

    function test_generateSubAccountAddress_NonZeroSubAccount() public view {
            address account = 0x1234567890AbcdEF1234567890aBcdef12345678;
            bytes1 subAccount = 0x01;
    
            address subAccountAddress = caller.generateSubAccountAddress(account, subAccount);
    
            // In Euler-style subaccounts the resulting address must be different from the base account
            assertTrue(subAccountAddress != account, "Subaccount address should differ from base account");
        }
}
// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {AssetDistributionProtectionLibCaller} from "test/test_helpers/lib_callers/AssetDistributionProtectionLibCaller.sol";

/// @dev Target: AssetDistributionProtectionLibCaller (library wrapped for Olympix targeting).

contract AssetDistributionProtectionLibTest is OlympixUnitTest("AssetDistributionProtectionLibCaller") {
    AssetDistributionProtectionLibCaller internal caller;

    function setUp() public override {
        caller = new AssetDistributionProtectionLibCaller();
    }

    function test_example_isMarketsLimitsActivatedDefaultsFalse() public view {
        assertFalse(caller.isMarketsLimitsActivated());
    }

    function test_example_activateThenIsActivated() public {
        caller.activateMarketsLimits();
        assertTrue(caller.isMarketsLimitsActivated());
    }

    function test_deactivateMarketsLimits() public {
            // Activate first so we know the flag can change
            caller.activateMarketsLimits();
            assertTrue(caller.isMarketsLimitsActivated());
    
            // Now call the target branch function and verify it deactivates
            caller.deactivateMarketsLimits();
            assertFalse(caller.isMarketsLimitsActivated());
        }
}
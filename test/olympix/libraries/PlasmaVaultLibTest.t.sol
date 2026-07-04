// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {PlasmaVaultLibCaller} from "test/test_helpers/lib_callers/PlasmaVaultLibCaller.sol";

/// @dev Target: PlasmaVaultLibCaller (library PlasmaVaultLib wrapped for Olympix targeting).

import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
contract PlasmaVaultLibTest is OlympixUnitTest("PlasmaVaultLibCaller") {
    PlasmaVaultLibCaller internal caller;

    function setUp() public override {
        caller = new PlasmaVaultLibCaller();
    }

    function test_example_deploys() public view {
        assertTrue(address(caller) != address(0));
    }

    function test_getTotalAssetsInAllMarkets_DefaultIsZeroAndBranchTrue() public view {
            // getTotalAssetsInAllMarkets() in PlasmaVaultLibCaller is wrapped in `if (true)`
            // so calling it will always execute the True branch (opix-target-branch-7-True).
            // With no prior configuration, the total assets across all markets should be 0.
    
            uint256 totalAssets = caller.getTotalAssetsInAllMarkets();
            assertEq(totalAssets, 0, "Total assets in all markets should be zero by default");
        }

    function test_getTotalAssetsInMarket_callsLibrary() public view {
            uint256 result = caller.getTotalAssetsInMarket(0);
            // No strict assertion possible without full PlasmaVaultLib context;
            // just ensure the call does not revert and returns a uint256.
            result;
        }

    function test_configureManagementFee_branchTrue() public {
            // when: call the wrapper so the PlasmaVaultLib.configureManagementFee branch is executed
            caller.configureManagementFee(address(0x1234), 100);
    
            // then: no revert means the branch was successfully executed
        }

    function test_configurePerformanceFee_branchTrue() public {
            address feeAccount = address(0xBEEF);
            // Fee is expressed in percentage with 2 decimals; must be <= PERFORMANCE_MAX_FEE_IN_PERCENTAGE (5000 = 50%).
            uint256 feePct = 100;

            caller.configurePerformanceFee(feeAccount, feePct);
    
            // No revert is expected; reaching here confirms branch hit
    //        assertTrue(true);
        }
    

    function test_getPriceOracleMiddlewareAfterSet() public {
            address newOracle = address(0x1234);
    
            // when: set a new price oracle middleware address
            caller.setPriceOracleMiddleware(newOracle);
    
            // then: getPriceOracleMiddleware should return the value just set
            assertEq(caller.getPriceOracleMiddleware(), newOracle);
        }

    function test_setPriceOracleMiddleware_updatesValue_viaCallerView() public {
            // given: initial oracle queried via the library itself
            address initialOracle = PlasmaVaultLib.getPriceOracleMiddleware();
    
            address newOracle = address(0x1234);
    
            // when: we set a new oracle via the caller (hits opix-target-branch-27-True)
            caller.setPriceOracleMiddleware(newOracle);
    
            // then: read back through the caller wrapper (same storage context)
            assertEq(caller.getPriceOracleMiddleware(), newOracle, "caller should see updated oracle");
    
            // and ensure that the library still returns some address (not asserting exact value to avoid context mismatch)
            address libOracle = PlasmaVaultLib.getPriceOracleMiddleware();
            libOracle; // silence warning
        }

    function test_getRewardsClaimManagerAddress_afterSet() public {
            // when: set a rewards claim manager address via the caller (which writes through PlasmaVaultLib)
            address expectedMgr = address(0xBEEF);
            caller.setRewardsClaimManagerAddress(expectedMgr);
    
            // then: getRewardsClaimManagerAddress should return the same value, exercising the wrapped branch
            address actualMgr = caller.getRewardsClaimManagerAddress();
            assertEq(actualMgr, expectedMgr, "rewards claim manager address mismatch");
        }

    function test_setRewardsClaimManagerAddress_updatesValue() public {
            address mgr = address(0x1234);
    
            // Initially zero
            assertEq(caller.getRewardsClaimManagerAddress(), address(0));
    
            // Act: set via wrapper (hits PlasmaVaultLibCaller.setRewardsClaimManagerAddress)
            caller.setRewardsClaimManagerAddress(mgr);
    
            // Assert: value updated in library storage
            assertEq(caller.getRewardsClaimManagerAddress(), mgr);
        }

    function test_getTotalSupplyCap_DefaultIsZeroAndCanBeUpdated() public {
            // default should be 0
            uint256 initialCap = caller.getTotalSupplyCap();
            assertEq(initialCap, 0);
    
            // when: update cap
            uint256 newCap = 1_000_000 ether;
            caller.setTotalSupplyCap(newCap);
    
            // then: getter reflects new value
            uint256 updatedCap = caller.getTotalSupplyCap();
            assertEq(updatedCap, newCap);
        }

    function test_setTotalSupplyCap_updatesValue() public {
            uint256 newCap = 1_000_000e18;
    
            // when: set a new total supply cap via the wrapper
            caller.setTotalSupplyCap(newCap);
    
            // then: the getter should return the newly set cap
            uint256 storedCap = caller.getTotalSupplyCap();
            assertEq(storedCap, newCap, "Total supply cap should be updated to the new value");
        }

    function test_isExecutionStarted_BranchTrue() public {
            // initially, execution should not be started
            assertFalse(caller.isExecutionStarted());
    
            // start execution to flip the internal PlasmaVaultLib flag
            caller.executeStarted();
    
            // now isExecutionStarted() should return true, hitting the opix-target-branch-47-True branch
            assertTrue(caller.isExecutionStarted());
    
            // finish execution to reset the flag and ensure it goes back to false
            caller.executeFinished();
            assertFalse(caller.isExecutionStarted());
        }

    function test_executeStarted_SetsExecutionStartedTrue() public {
            // pre-condition: execution not started
            assertFalse(caller.isExecutionStarted());
    
            // when: we call executeStarted on the wrapper (which calls PlasmaVaultLib.executeStarted())
            caller.executeStarted();
    
            // then: execution flag should be true
            assertTrue(caller.isExecutionStarted());
        }

    function test_executeFinished_setsExecutionFlagFalse() public {
            // Initially, execution should not be started
            assertFalse(caller.isExecutionStarted());
    
            // Start execution
            caller.executeStarted();
            assertTrue(caller.isExecutionStarted());
    
            // Finish execution - this must hit PlasmaVaultLibCaller.executeFinished()'s body
            caller.executeFinished();
    
            // After finishing, execution flag should be false again
            assertFalse(caller.isExecutionStarted());
        }
}
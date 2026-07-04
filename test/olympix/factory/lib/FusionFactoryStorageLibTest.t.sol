// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {FusionFactoryStorageLibCaller} from "test/test_helpers/lib_callers/FusionFactoryStorageLibCaller.sol";

/// @dev Target: FusionFactoryStorageLibCaller (library FusionFactoryStorageLib wrapped for Olympix targeting).

import {FusionFactoryStorageLib} from "contracts/factory/lib/FusionFactoryStorageLib.sol";
contract FusionFactoryStorageLibTest is OlympixUnitTest("FusionFactoryStorageLibCaller") {
    FusionFactoryStorageLibCaller internal caller;

    function setUp() public override {
        caller = new FusionFactoryStorageLibCaller();
    }

    function test_example_deploys() public view {
        assertTrue(address(caller) != address(0));
    }

    function test_getFusionFactoryVersion_BranchTrue() public {
            // set a known version value via the caller wrapper (writes through the library)
            caller.setFusionFactoryVersion(42);
    
            // when: calling the getter which is wrapped in an `if (true)` block targeting branch id 7
            uint256 version = caller.getFusionFactoryVersion();
    
            // then: the stored value is returned, meaning the if-true branch was executed
            assertEq(version, 42);
        }

    function test_setFusionFactoryVersion_UpdatesStorage() public {
            // given
            uint256 versionBefore = caller.getFusionFactoryVersion();
            uint256 newVersion = versionBefore + 1;
    
            // when
            caller.setFusionFactoryVersion(newVersion);
    
            // then
            uint256 versionAfter = caller.getFusionFactoryVersion();
            assertEq(versionAfter, newVersion, "FusionFactoryVersion should be updated to newVersion");
        }

    function test_getFusionFactoryIndex_DefaultIsZero() public view {
            uint256 index = caller.getFusionFactoryIndex();
            assertEq(index, 0);
        }

    function test_setFusionFactoryIndex_updatesStorage() public {
            // given: initial index is 0
            uint256 initialIndex = caller.getFusionFactoryIndex();
            assertEq(initialIndex, 0, "initial index should be zero");
    
            // when: set a new index
            uint256 newIndex = 42;
            caller.setFusionFactoryIndex(newIndex);
    
            // then: stored index should be updated
            uint256 storedIndex = caller.getFusionFactoryIndex();
            assertEq(storedIndex, newIndex, "fusion factory index should be updated");
        }

    function test_setAndGetPlasmaVaultAdminArray() public {
            // given: prepare an array of admin addresses
            address[] memory adminsIn = new address[](3);
            adminsIn[0] = address(0x1);
            adminsIn[1] = address(0x2);
            adminsIn[2] = address(0x3);
    
            // when: store via setter
            caller.setPlasmaVaultAdminArray(adminsIn);
    
            // then: read back via getter (hits opix-target-branch-23-True)
            address[] memory adminsOut = caller.getPlasmaVaultAdminArray();
    
            assertEq(adminsOut.length, 3, "admins length");
            assertEq(adminsOut[0], address(0x1), "admin 0");
            assertEq(adminsOut[1], address(0x2), "admin 1");
            assertEq(adminsOut[2], address(0x3), "admin 2");
        }

    function test_setPlasmaVaultAdminArray_updatesStorage() public {
            // prepare an array of admin addresses
            address[] memory admins = new address[](2);
            admins[0] = address(0x1);
            admins[1] = address(0x2);
    
            // when: set the admins array via the caller (this will enter the opix-target-branch-27-True branch)
            caller.setPlasmaVaultAdminArray(admins);
    
            // then: read back and verify
            address[] memory returnedAdmins = caller.getPlasmaVaultAdminArray();
            assertEq(returnedAdmins.length, 2, "admins length");
            assertEq(returnedAdmins[0], address(0x1), "admin[0]");
            assertEq(returnedAdmins[1], address(0x2), "admin[1]");
        }

    function test_getPriceOracleMiddleware_readsValueSetBySetter() public {
            // given: set a specific middleware address via the setter
            address expected = address(0xABCD);
            caller.setPriceOracleMiddlewareAddress(expected);
    
            // when: read via the wrapper, which internally calls FusionFactoryStorageLib.getPriceOracleMiddleware()
            address actual = caller.getPriceOracleMiddleware();
    
            // then: the returned value should match what we set
            assertEq(actual, expected, "price oracle middleware stored in FusionFactoryStorageLib should match");
        }

    function test_setPriceOracleMiddlewareAddress_BranchTrue() public {
            // given: choose a non-zero middleware address
            address expected = address(0xBEEF);
    
            // when: call the wrapper setter, which is guarded by `if (true)` and targets opix-target-branch-35-True
            caller.setPriceOracleMiddlewareAddress(expected);
    
            // then: underlying FusionFactoryStorageLib storage should reflect the new value
            address actual = caller.getPriceOracleMiddleware();
            assertEq(actual, expected, "price oracle middleware should be updated via branch-35-True path");
        }

    function test_getWithdrawWindowInSeconds_afterSet_returnsValue() public {
            // given: set a specific withdraw window value via the caller wrapper
            uint256 expected = 1234;
            caller.setWithdrawWindowInSeconds(expected);
    
            // when: read back using the getter that contains the target branch (opix-target-branch-39-True)
            uint256 actual = caller.getWithdrawWindowInSeconds();
    
            // then: value returned from the library-backed storage should match what we set
            assertEq(actual, expected, "withdraw window should match value set");
        }

    function test_setWithdrawWindowInSeconds_updatesValue() public {
            // given: choose a non-zero withdraw window
            uint256 newWindow = 3600;
    
            // when: call the wrapper setter, which internally enters the opix-target-branch-43-True branch
            caller.setWithdrawWindowInSeconds(newWindow);
    
            // then: getter should return the updated value, confirming storage was written via the library
            uint256 stored = caller.getWithdrawWindowInSeconds();
            assertEq(stored, newWindow, "withdraw window should be updated to the new value");
        }

    function test_getVestingPeriodInSeconds_DefaultZeroThenUpdated() public {
            // default should be 0
            uint256 initial = caller.getVestingPeriodInSeconds();
            assertEq(initial, 0, "initial vesting period should be zero");
    
            // when: set a non‑zero vesting period
            uint256 newPeriod = 7 days;
            caller.setVestingPeriodInSeconds(newPeriod);
    
            // then: getter should return the updated value, hitting the wrapped library branch
            uint256 updated = caller.getVestingPeriodInSeconds();
            assertEq(updated, newPeriod, "vesting period should be updated");
        }

    function test_setVestingPeriodInSeconds_updatesStorage() public {
        // given: initial vesting period is zero
        uint256 initial = caller.getVestingPeriodInSeconds();
        assertEq(initial, 0, "initial vesting period should be 0");
    
        // when: we set a new vesting period
        uint256 newPeriod = 7 days;
        caller.setVestingPeriodInSeconds(newPeriod);
    
        // then: storage in FusionFactoryStorageLib is updated
        uint256 stored = caller.getVestingPeriodInSeconds();
        assertEq(stored, newPeriod, "vesting period should be updated to new value");
    }

    function test_getDaoFeePackagesLength_DefaultIsZero() public view {
            uint256 len = caller.getDaoFeePackagesLength();
            assertEq(len, 0, "default dao fee packages length should be zero");
        }
}
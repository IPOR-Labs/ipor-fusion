// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {PlasmaVaultFeesLibCaller} from "test/test_helpers/lib_callers/PlasmaVaultFeesLibCaller.sol";

/// @dev Target: PlasmaVaultFeesLibCaller (library PlasmaVaultFeesLib wrapped for Olympix targeting).

import {PlasmaVaultFeesLib} from "contracts/vaults/lib/PlasmaVaultFeesLib.sol";
contract PlasmaVaultFeesLibTest is OlympixUnitTest("PlasmaVaultFeesLibCaller") {
    PlasmaVaultFeesLibCaller internal caller;

    function setUp() public override {
        caller = new PlasmaVaultFeesLibCaller();
    }

    function test_example_deploys() public view {
        assertTrue(address(caller) != address(0));
    }

    function test_prepareForRealizeDepositFee_TargetBranch() public view {
            // The wrapper unconditionally executes the `if (true)` branch inside
            // prepareForRealizeDepositFee, so any call will hit the targeted branch.
            // We only need to ensure the call succeeds and returns without reverting.
    
            (address recipient, uint256 feeShares) = caller.prepareForRealizeDepositFee(0);
    
            // Basic usage of returned values to avoid warnings and ensure the path is exercised
            recipient;
            feeShares;
        }
    

    function test_prepareForRealizeManagementFee_basicCall() public view {
            // when
            (address feeAccount, uint256 amount) = caller.prepareForRealizeManagementFee(1 ether);
    
            // then - just basic sanity checks to exercise the branch
            // Library may return zero values depending on internal state; we only assert non-reverts.
            feeAccount; // silence unused var warning
            amount;     // silence unused var warning
        }

    function test_getUnrealizedManagementFee_TargetTrueBranch() public view {
            // When totalAssets_ is zero, unrealized management fee should be zero.
            uint256 feeZeroAssets = caller.getUnrealizedManagementFee(0);
            assertEq(feeZeroAssets, 0, "Fee should be zero when total assets are zero");
    
            // Also call the library directly to ensure the wrapped path is exercised and result matches.
            uint256 libFeeZeroAssets = PlasmaVaultFeesLib.getUnrealizedManagementFee(0);
            assertEq(feeZeroAssets, libFeeZeroAssets, "Caller and library results should match");
        }
}
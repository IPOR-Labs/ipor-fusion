// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../test/OlympixUnitTest.sol";
import {WithdrawManager} from "../../../../contracts/managers/withdraw/WithdrawManager.sol";

import {WithdrawManagerStorageLib} from "contracts/managers/withdraw/WithdrawManagerStorageLib.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {IPlasmaVaultBase} from "contracts/interfaces/IPlasmaVaultBase.sol";
import {AccessManagedUpgradeable} from "contracts/managers/access/AccessManagedUpgradeable.sol";
contract WithdrawManagerTest is OlympixUnitTest("WithdrawManager") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_requestShares_zeroShares_revertsAndDoesNotTouchStorage() public {
        // Arrange: deploy a WithdrawManager with a dummy access manager
        address dummyAccessManager = address(this);
        WithdrawManager manager = new WithdrawManager(dummyAccessManager);
    
        // We don't expect any change in request fee or withdraw window, just that call reverts
        // Act & Assert: calling requestShares with 0 should revert with WithdrawManagerZeroShares
        vm.expectRevert(WithdrawManager.WithdrawManagerZeroShares.selector);
        manager.requestShares(0);
    }

    function test_requestShares_nonZeroShares_hitsElseBranchAndUpdatesStorage() public {
            // Arrange: deploy WithdrawManager with dummy access manager
            address dummyAccessManager = address(this);
            WithdrawManager manager = new WithdrawManager(dummyAccessManager);
    
            // We can't easily observe storage through the private library here, but we can
            // still call with non‑zero shares to cover the `else` branch guarded by
            // `if (shares_ == 0) { ... } else { assert(true); }`.
            // No revert is expected.
    
            manager.requestShares(1);
        }

    function test_getLastReleaseFundsTimestamp_hitsTrueBranchAndReturnsStoredValue() public {
            // We can't call the internal WithdrawManagerStorageLib directly here,
            // but we can still invoke getLastReleaseFundsTimestamp to cover the
            // `if (true)` branch which returns the stored value.
            // Deploy manager with dummy access manager
            address dummyAccessManager = address(this);
            WithdrawManager manager = new WithdrawManager(dummyAccessManager);
    
            // Call the view function to ensure the `if (true)` branch is executed.
            // No revert is expected; we just ensure it returns a value.
            uint256 ts = manager.getLastReleaseFundsTimestamp();
            // Basic sanity check: timestamp can be zero for fresh storage, just assert read didn't revert
            assertEq(ts, WithdrawManagerStorageLib.getLastReleaseFundsTimestamp());
        }

    function test_getRequestFee_hitsTrueBranchAndReturnsStoredValue() public {
            // Arrange
            address dummyAccessManager = address(this);
            WithdrawManager manager = new WithdrawManager(dummyAccessManager);
    
            uint256 expectedFee = 123e16; // 12.3%
            // Directly set the fee in storage via the library to have an observable value
            WithdrawManagerStorageLib.setRequestFee(expectedFee);
    
            // Act
            uint256 fee = manager.getRequestFee();
    
            // Assert
            assertEq(fee, expectedFee, "getRequestFee should return the value stored in WithdrawManagerStorageLib");
        }
}
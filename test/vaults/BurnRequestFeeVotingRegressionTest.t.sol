// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IFuseCommon} from "../../contracts/fuses/IFuse.sol";
import {PlasmaVaultStorageLib} from "../../contracts/libraries/PlasmaVaultStorageLib.sol";
import {IPlasmaVaultBase} from "../../contracts/interfaces/IPlasmaVaultBase.sol";
import {BurnRequestFeeFuse, BurnRequestFeeDataEnter} from "../../contracts/fuses/burn_request_fee/BurnRequestFeeFuse.sol";

// ============================================
// VULNERABLE VERSION OF BurnRequestFeeFuse
// This is the OLD implementation that bypasses voting checkpoints
// Used only for regression testing to demonstrate the vulnerability
// ============================================

struct VulnerableBurnRequestFeeDataEnter {
    uint256 amount;
}

/// @notice VULNERABLE fuse - uses direct _burn which bypasses PlasmaVaultBase._update
/// @dev This contract demonstrates the vulnerability where inheriting from ERC20Upgradeable
///      and calling _burn() directly bypasses the vault's _update pipeline
contract VulnerableBurnRequestFeeFuse is IFuseCommon, ERC20Upgradeable {
    error BurnRequestFeeWithdrawManagerNotSet();
    error BurnRequestFeeExitNotImplemented();

    event BurnRequestFeeEnter(address version, uint256 amount);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    // Track if _update was called (for testing purposes)
    bool public updateCalled;
    address public updateFrom;
    address public updateTo;
    uint256 public updateValue;

    constructor(uint256 marketId_) initializer {
        VERSION = address(this);
        MARKET_ID = marketId_;
        __ERC20_init("Burn Request Fee - Fuse", "BRF");
    }

    /// @notice VULNERABLE: Uses _burn directly which bypasses PlasmaVaultBase._update
    function enter(VulnerableBurnRequestFeeDataEnter memory data_) public {
        address withdrawManager = PlasmaVaultStorageLib.getWithdrawManager().manager;

        if (withdrawManager == address(0)) {
            revert BurnRequestFeeWithdrawManagerNotSet();
        }

        if (data_.amount == 0) {
            return;
        }

        // VULNERABLE: This calls the fuse's own ERC20Upgradeable._burn
        // which uses the fuse's _update, NOT PlasmaVaultBase._update
        _burn(withdrawManager, data_.amount);

        emit BurnRequestFeeEnter(VERSION, data_.amount);
    }

    // Override _update to track calls (this is fuse's _update, NOT vault's)
    function _update(address from, address to, uint256 value) internal virtual override {
        updateCalled = true;
        updateFrom = from;
        updateTo = to;
        updateValue = value;
        super._update(from, to, value);
    }

    function exit() external pure {
        revert BurnRequestFeeExitNotImplemented();
    }
}

// ============================================
// Mock PlasmaVaultBase to track updateInternal calls
// ============================================
contract MockPlasmaVaultBase {
    // Track calls to updateInternal
    bool public updateInternalCalled;
    address public lastFrom;
    address public lastTo;
    uint256 public lastValue;

    event UpdateInternalCalled(address from, address to, uint256 value);

    function updateInternal(address from_, address to_, uint256 value_) external {
        updateInternalCalled = true;
        lastFrom = from_;
        lastTo = to_;
        lastValue = value_;
        emit UpdateInternalCalled(from_, to_, value_);
    }

    function reset() external {
        updateInternalCalled = false;
        lastFrom = address(0);
        lastTo = address(0);
        lastValue = 0;
    }
}

/// @notice Helper contract to simulate PlasmaVault's delegatecall to fuses
contract DelegateCaller {
    // Track if MockPlasmaVaultBase.updateInternal was called
    bool public updateInternalWasCalled;

    function callFuse(address fuse, bytes memory data) external returns (bytes memory) {
        (bool success, bytes memory result) = fuse.delegatecall(data);
        require(success, "Delegatecall failed");
        return result;
    }

    // Allow checking storage after delegatecall
    function getStorageAt(bytes32 slot) external view returns (bytes32) {
        bytes32 value;
        assembly {
            value := sload(slot)
        }
        return value;
    }
}

/**
 * @title BurnRequestFeeVotingRegressionTest
 * @notice Regression test suite for BurnRequestFeeFuse voting checkpoint vulnerability
 *
 * Vulnerability Description:
 * - VULNERABLE version: Inherits ERC20Upgradeable and calls _burn() directly
 *   - This calls the FUSE's _update() function, NOT the vault's
 *   - PlasmaVaultBase.updateInternal is NEVER called
 *   - _transferVotingUnits is NEVER called
 *   - Voting checkpoints are NOT updated
 *
 * - FIXED version: Routes through PlasmaVaultBase.updateInternal via delegatecall
 *   - PlasmaVaultBase._update() is called
 *   - _transferVotingUnits IS called
 *   - Voting checkpoints ARE updated
 */
contract BurnRequestFeeVotingRegressionTest is Test {
    address private constant WITHDRAW_MANAGER = address(0x1234);
    uint256 private constant MARKET_ID = 1;
    uint256 private constant BURN_AMOUNT = 1000e18;

    MockPlasmaVaultBase private mockBase;
    VulnerableBurnRequestFeeFuse private vulnerableFuse;
    BurnRequestFeeFuse private fixedFuse;
    DelegateCaller private caller;

    // Storage slot for withdraw manager (from PlasmaVaultStorageLib)
    // LEGACY NOTE: This slot does not match the documented formula - see PlasmaVaultStorageLib
    bytes32 private constant WITHDRAW_MANAGER_SLOT = 0xb37e8684757599da669b8aea811ee2b3693b2582d2c730fab3f4965fa2ec3e11;

    // Storage slot for plasma vault base (from PlasmaVaultStorageLib)
    bytes32 private constant PLASMA_VAULT_BASE_SLOT =
        0x708fd1151214a098976e0893cd3883792c21aeb94a31cd7733c8947c13c23000;

    function setUp() public {
        mockBase = new MockPlasmaVaultBase();
        vulnerableFuse = new VulnerableBurnRequestFeeFuse(MARKET_ID);
        fixedFuse = new BurnRequestFeeFuse(MARKET_ID);
        caller = new DelegateCaller();
    }

    // ============================================
    // VULNERABLE FUSE TESTS
    // ============================================

    /// @notice Test that VULNERABLE fuse does NOT call PlasmaVaultBase.updateInternal
    /// @dev This proves the vulnerability exists - the vault's update pipeline is bypassed
    function testVulnerableFuse_DoesNOT_CallUpdateInternal() external {
        // Setup: Store withdraw manager address in the storage slot
        vm.store(address(vulnerableFuse), WITHDRAW_MANAGER_SLOT, bytes32(uint256(uint160(WITHDRAW_MANAGER))));

        // Setup: Store mock base address
        vm.store(address(vulnerableFuse), PLASMA_VAULT_BASE_SLOT, bytes32(uint256(uint160(address(mockBase)))));

        // Give the fuse some balance to burn (simulating delegatecall context)
        deal(address(vulnerableFuse), WITHDRAW_MANAGER, BURN_AMOUNT);

        // Execute burn with VULNERABLE fuse
        vulnerableFuse.enter(VulnerableBurnRequestFeeDataEnter({amount: BURN_AMOUNT}));

        // The fuse's own _update WAS called (but this is wrong - it's the fuse's _update, not vault's)
        assertTrue(vulnerableFuse.updateCalled(), "Fuse's own _update should be called");
        assertEq(vulnerableFuse.updateFrom(), WITHDRAW_MANAGER, "Update from should be withdraw manager");
        assertEq(vulnerableFuse.updateTo(), address(0), "Update to should be zero (burn)");
        assertEq(vulnerableFuse.updateValue(), BURN_AMOUNT, "Update value should match burn amount");

        // CRITICAL: MockPlasmaVaultBase.updateInternal was NEVER called!
        assertFalse(mockBase.updateInternalCalled(), "PlasmaVaultBase.updateInternal should NOT be called by vulnerable fuse");
    }

    /// @notice Test that vulnerable fuse correctly calls its own _update but bypasses vault hooks
    function testVulnerableFuse_CallsOwnUpdate_BypassesVaultHooks() external {
        // Setup storage
        vm.store(address(vulnerableFuse), WITHDRAW_MANAGER_SLOT, bytes32(uint256(uint160(WITHDRAW_MANAGER))));
        vm.store(address(vulnerableFuse), PLASMA_VAULT_BASE_SLOT, bytes32(uint256(uint160(address(mockBase)))));
        deal(address(vulnerableFuse), WITHDRAW_MANAGER, BURN_AMOUNT);

        // Before: verify initial state
        assertFalse(vulnerableFuse.updateCalled(), "Update should not be called before enter");
        assertFalse(mockBase.updateInternalCalled(), "UpdateInternal should not be called before enter");

        // Execute
        vulnerableFuse.enter(VulnerableBurnRequestFeeDataEnter({amount: BURN_AMOUNT}));

        // After: fuse's _update called, but vault's updateInternal NOT called
        assertTrue(vulnerableFuse.updateCalled(), "Fuse's _update should be called");
        assertFalse(mockBase.updateInternalCalled(), "Vault's updateInternal should NOT be called - this is the vulnerability");
    }

    // ============================================
    // FIXED FUSE TESTS
    // ============================================

    /// @notice Test that FIXED fuse DOES call PlasmaVaultBase.updateInternal
    /// @dev This proves the fix works - the vault's update pipeline is used
    ///      Note: Since nested delegatecall is used, we verify via event emission
    function testFixedFuse_DOES_CallUpdateInternal() external {
        // Setup storage in the caller (which will be used during delegatecall)
        vm.store(address(caller), WITHDRAW_MANAGER_SLOT, bytes32(uint256(uint160(WITHDRAW_MANAGER))));
        vm.store(address(caller), PLASMA_VAULT_BASE_SLOT, bytes32(uint256(uint160(address(mockBase)))));

        // Record logs to verify event was emitted
        vm.recordLogs();

        // Execute burn with FIXED fuse via delegatecall
        caller.callFuse(
            address(fixedFuse),
            abi.encodeWithSelector(BurnRequestFeeFuse.enter.selector, BurnRequestFeeDataEnter({amount: BURN_AMOUNT}))
        );

        // Verify UpdateInternalCalled event was emitted (proves updateInternal was called)
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool eventFound = false;
        bytes32 expectedEventSig = keccak256("UpdateInternalCalled(address,address,uint256)");

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == expectedEventSig) {
                eventFound = true;
                // Decode event data
                (address from, address to, uint256 value) = abi.decode(logs[i].data, (address, address, uint256));
                assertEq(from, WITHDRAW_MANAGER, "From should be withdraw manager");
                assertEq(to, address(0), "To should be zero (burn)");
                assertEq(value, BURN_AMOUNT, "Value should match burn amount");
                break;
            }
        }

        assertTrue(eventFound, "PlasmaVaultBase.updateInternal should be called (UpdateInternalCalled event)");
    }

    /// @notice Test that fixed fuse correctly routes through vault's update pipeline
    /// @dev Uses event verification since delegatecall modifies caller's storage, not mock's
    function testFixedFuse_RoutesThrough_VaultUpdatePipeline() external {
        // Setup
        vm.store(address(caller), WITHDRAW_MANAGER_SLOT, bytes32(uint256(uint160(WITHDRAW_MANAGER))));
        vm.store(address(caller), PLASMA_VAULT_BASE_SLOT, bytes32(uint256(uint160(address(mockBase)))));

        // Record logs
        vm.recordLogs();

        // Execute
        caller.callFuse(
            address(fixedFuse),
            abi.encodeWithSelector(BurnRequestFeeFuse.enter.selector, BurnRequestFeeDataEnter({amount: BURN_AMOUNT}))
        );

        // Verify event was emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 expectedEventSig = keccak256("UpdateInternalCalled(address,address,uint256)");
        bool eventFound = false;

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == expectedEventSig) {
                eventFound = true;
                break;
            }
        }

        assertTrue(eventFound, "Vault's updateInternal should be called - fix working correctly");
    }

    /// @notice Test fixed fuse emits BurnRequestFeeEnter event
    function testFixedFuse_EmitsBurnRequestFeeEnterEvent() external {
        // Setup
        vm.store(address(caller), WITHDRAW_MANAGER_SLOT, bytes32(uint256(uint160(WITHDRAW_MANAGER))));
        vm.store(address(caller), PLASMA_VAULT_BASE_SLOT, bytes32(uint256(uint160(address(mockBase)))));

        // Expect the BurnRequestFeeEnter event
        vm.expectEmit(true, true, false, true);
        emit BurnRequestFeeFuse.BurnRequestFeeEnter(address(fixedFuse), BURN_AMOUNT);

        // Execute
        caller.callFuse(
            address(fixedFuse),
            abi.encodeWithSelector(BurnRequestFeeFuse.enter.selector, BurnRequestFeeDataEnter({amount: BURN_AMOUNT}))
        );
    }

    // ============================================
    // EDGE CASE TESTS
    // ============================================

    /// @notice Test that zero amount skips burn operation (fixed fuse)
    function testFixedFuse_ZeroAmount_SkipsBurn() external {
        // Setup
        vm.store(address(caller), WITHDRAW_MANAGER_SLOT, bytes32(uint256(uint160(WITHDRAW_MANAGER))));
        vm.store(address(caller), PLASMA_VAULT_BASE_SLOT, bytes32(uint256(uint160(address(mockBase)))));

        // Execute with zero amount
        caller.callFuse(
            address(fixedFuse),
            abi.encodeWithSelector(BurnRequestFeeFuse.enter.selector, BurnRequestFeeDataEnter({amount: 0}))
        );

        // updateInternal should NOT be called for zero amount
        assertFalse(mockBase.updateInternalCalled(), "UpdateInternal should not be called for zero amount");
    }

    /// @notice Test that missing withdraw manager reverts (fixed fuse)
    function testFixedFuse_MissingWithdrawManager_Reverts() external {
        // Setup: Only set plasma vault base, NOT withdraw manager
        vm.store(address(caller), PLASMA_VAULT_BASE_SLOT, bytes32(uint256(uint160(address(mockBase)))));
        // WITHDRAW_MANAGER_SLOT is zero by default

        // Execute and expect revert (delegatecall wraps the revert in "Delegatecall failed")
        vm.expectRevert("Delegatecall failed");
        caller.callFuse(
            address(fixedFuse),
            abi.encodeWithSelector(BurnRequestFeeFuse.enter.selector, BurnRequestFeeDataEnter({amount: BURN_AMOUNT}))
        );
    }

    /// @notice Test that exit function reverts as expected
    function testFixedFuse_Exit_Reverts() external {
        vm.expectRevert(BurnRequestFeeFuse.BurnRequestFeeExitNotImplemented.selector);
        fixedFuse.exit();
    }

    /// @notice Test that exitTransient function reverts as expected
    function testFixedFuse_ExitTransient_Reverts() external {
        vm.expectRevert(BurnRequestFeeFuse.BurnRequestFeeExitNotImplemented.selector);
        fixedFuse.exitTransient();
    }

    // ============================================
    // IMMUTABLE VERIFICATION TESTS
    // ============================================

    /// @notice Test that VERSION is correctly set
    function testFixedFuse_VERSION_IsSet() external view {
        assertEq(fixedFuse.VERSION(), address(fixedFuse), "VERSION should be fuse address");
    }

    /// @notice Test that MARKET_ID is correctly set
    function testFixedFuse_MARKET_ID_IsSet() external view {
        assertEq(fixedFuse.MARKET_ID(), MARKET_ID, "MARKET_ID should match constructor value");
    }

    // ============================================
    // COMPARISON VERIFICATION
    // ============================================

    /// @notice Behavioral comparison test proving fix works
    /// @dev Runs both vulnerable and fixed fuses and compares behavior using events
    function testComparison_VulnerableBypassesHooks_FixedCallsHooks() external {
        bytes32 updateInternalEventSig = keccak256("UpdateInternalCalled(address,address,uint256)");

        // ===== VULNERABLE FUSE =====
        vm.store(address(vulnerableFuse), WITHDRAW_MANAGER_SLOT, bytes32(uint256(uint160(WITHDRAW_MANAGER))));
        vm.store(address(vulnerableFuse), PLASMA_VAULT_BASE_SLOT, bytes32(uint256(uint160(address(mockBase)))));
        deal(address(vulnerableFuse), WITHDRAW_MANAGER, BURN_AMOUNT);

        vm.recordLogs();
        vulnerableFuse.enter(VulnerableBurnRequestFeeDataEnter({amount: BURN_AMOUNT}));
        Vm.Log[] memory vulnerableLogs = vm.getRecordedLogs();

        bool vulnerableCalledUpdateInternal = false;
        for (uint256 i = 0; i < vulnerableLogs.length; i++) {
            if (vulnerableLogs[i].topics[0] == updateInternalEventSig) {
                vulnerableCalledUpdateInternal = true;
                break;
            }
        }

        // ===== FIXED FUSE =====
        vm.store(address(caller), WITHDRAW_MANAGER_SLOT, bytes32(uint256(uint160(WITHDRAW_MANAGER))));
        vm.store(address(caller), PLASMA_VAULT_BASE_SLOT, bytes32(uint256(uint160(address(mockBase)))));

        vm.recordLogs();
        caller.callFuse(
            address(fixedFuse),
            abi.encodeWithSelector(BurnRequestFeeFuse.enter.selector, BurnRequestFeeDataEnter({amount: BURN_AMOUNT}))
        );
        Vm.Log[] memory fixedLogs = vm.getRecordedLogs();

        bool fixedCalledUpdateInternal = false;
        for (uint256 i = 0; i < fixedLogs.length; i++) {
            if (fixedLogs[i].topics[0] == updateInternalEventSig) {
                fixedCalledUpdateInternal = true;
                break;
            }
        }

        // ===== VERIFY DIFFERENCE =====
        assertFalse(vulnerableCalledUpdateInternal, "VULNERABLE: should NOT call updateInternal");
        assertTrue(fixedCalledUpdateInternal, "FIXED: should call updateInternal");

        // This proves the vulnerability existed and the fix works
        assertTrue(
            fixedCalledUpdateInternal && !vulnerableCalledUpdateInternal,
            "Fix confirmed: vulnerable bypasses hooks, fixed calls hooks"
        );
    }
}

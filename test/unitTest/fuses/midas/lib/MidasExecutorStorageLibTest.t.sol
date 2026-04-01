// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MidasExecutorStorageLib} from "contracts/fuses/midas/lib/MidasExecutorStorageLib.sol";
import {MidasExecutor} from "contracts/fuses/midas/MidasExecutor.sol";

/// @dev Harness that exposes MidasExecutorStorageLib internal functions for testing.
///      Deployed as a standalone contract so that ERC-7201 storage is per-instance.
contract MidasExecutorStorageLibHarness {
    function getExecutor() external view returns (address) {
        return MidasExecutorStorageLib.getExecutor();
    }

    function setExecutor(address executor_) external {
        MidasExecutorStorageLib.setExecutor(executor_);
    }

    function getOrCreateExecutor(address plasmaVault_) external returns (address) {
        return MidasExecutorStorageLib.getOrCreateExecutor(plasmaVault_);
    }

    /// @dev Returns the raw storage slot used by the library (via inline assembly).
    function getExecutorStorageSlot() external pure returns (bytes32 slot) {
        MidasExecutorStorageLib.MidasExecutorStorage storage s = MidasExecutorStorageLib.getExecutorStorage();
        assembly {
            slot := s.slot
        }
    }
}

contract MidasExecutorStorageLibTest is Test {
    /// @dev ERC-7201 slot constant, mirrors the library value for direct comparison
    bytes32 internal constant MIDAS_EXECUTOR_SLOT =
        0x70d197bb241b100c004ed80fc4b87ce41500fa5c47b2ad133730792ea68d7d00;

    MidasExecutorStorageLibHarness internal harness;

    function setUp() public {
        harness = new MidasExecutorStorageLibHarness();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 4.1  ERC-7201 Storage Slot Verification (B1)
    // ══════════════════════════════════════════════════════════════════════════

    /// @dev B1 — slot returned by the library matches the ERC-7201 formula.
    function testGetExecutorStorage_SlotMatchesERC7201Calculation() public view {
        bytes32 expectedSlot = keccak256(
            abi.encode(uint256(keccak256("io.ipor.midas.Executor")) - 1)
        ) & ~bytes32(uint256(0xff));

        bytes32 actualSlot = harness.getExecutorStorageSlot();

        assertEq(actualSlot, expectedSlot, "slot must match ERC-7201 formula");
    }

    /// @dev B1 — slot returned by the library equals the hardcoded constant.
    function testGetExecutorStorage_SlotEqualsHardcodedValue() public view {
        bytes32 actualSlot = harness.getExecutorStorageSlot();
        assertEq(actualSlot, MIDAS_EXECUTOR_SLOT, "slot must equal the hardcoded constant");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 4.2  getExecutor() (B2, B3)
    // ══════════════════════════════════════════════════════════════════════════

    /// @dev B2 — default state: no executor set, returns address(0).
    function testGetExecutor_ReturnsZeroWhenNotSet() public view {
        assertEq(harness.getExecutor(), address(0), "fresh harness must return address(0)");
    }

    /// @dev B3 — after setExecutor, getExecutor returns the stored address.
    function testGetExecutor_ReturnsStoredAddress() public {
        address someAddress = address(0xBEEF);
        harness.setExecutor(someAddress);
        assertEq(harness.getExecutor(), someAddress, "must return the previously stored address");
    }

    /// @dev B3 — getExecutor reads from the correct ERC-7201 slot (verified via vm.store).
    function testGetExecutor_ReadsFromCorrectStorageSlot() public {
        address expected = address(0xC0FFEE);
        // Write directly to the ERC-7201 slot inside the harness contract's storage.
        vm.store(
            address(harness),
            MIDAS_EXECUTOR_SLOT,
            bytes32(uint256(uint160(expected)))
        );

        assertEq(harness.getExecutor(), expected, "must read from the correct ERC-7201 slot");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 4.3  setExecutor() (B4, B5, B6)
    // ══════════════════════════════════════════════════════════════════════════

    /// @dev B4 — setExecutor writes a non-zero address; verified via getter and raw storage.
    function testSetExecutor_WritesNonZeroAddress() public {
        address addr = address(0xBEEF);
        harness.setExecutor(addr);

        assertEq(harness.getExecutor(), addr, "getter must return the stored address");

        bytes32 rawSlot = vm.load(address(harness), MIDAS_EXECUTOR_SLOT);
        assertEq(rawSlot, bytes32(uint256(uint160(addr))), "raw storage must equal the address");
    }

    /// @dev B5 — setExecutor(address(0)) clears storage without reverting.
    function testSetExecutor_WritesZeroAddress() public {
        // Populate first so that overwrite-to-zero is meaningful.
        harness.setExecutor(address(0xBEEF));
        harness.setExecutor(address(0));

        assertEq(harness.getExecutor(), address(0), "must allow clearing executor to address(0)");
    }

    /// @dev B6 — setExecutor overwrites an existing non-zero address (last-write-wins).
    function testSetExecutor_OverwritesExistingAddress() public {
        harness.setExecutor(address(0xAAAA));
        harness.setExecutor(address(0xBBBB));

        assertEq(harness.getExecutor(), address(0xBBBB), "must overwrite the previous executor address");
    }

    /// @dev B4 — setExecutor writes to the correct ERC-7201 slot (verified via vm.load).
    function testSetExecutor_WritesToCorrectStorageSlot() public {
        address addr = address(0xDEAD);
        harness.setExecutor(addr);

        bytes32 rawSlot = vm.load(address(harness), MIDAS_EXECUTOR_SLOT);
        assertEq(
            rawSlot,
            bytes32(uint256(uint160(addr))),
            "setExecutor must write to the correct ERC-7201 slot"
        );
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 4.4  getOrCreateExecutor() (B7, B8, B9)
    // ══════════════════════════════════════════════════════════════════════════

    /// @dev B8 — deploys a new MidasExecutor when none exists; verifies deployment, storage, and constructor arg.
    function testGetOrCreateExecutor_DeploysNewExecutorWhenNoneExists() public {
        address plasmaVault = address(this);

        address returned = harness.getOrCreateExecutor(plasmaVault);

        // 1. Returned address must be non-zero.
        assertTrue(returned != address(0), "returned executor must be non-zero");

        // 2. Storage must be updated to the returned address.
        assertEq(harness.getExecutor(), returned, "storage must hold the newly deployed executor");

        // 3. Constructor was called with the correct plasmaVault.
        assertEq(
            MidasExecutor(returned).PLASMA_VAULT(),
            plasmaVault,
            "MidasExecutor must store the correct PLASMA_VAULT"
        );

        // 4. The returned address has contract code.
        assertGt(returned.code.length, 0, "returned address must be a deployed contract");
    }

    /// @dev B7 — second call returns the same executor without redeployment.
    function testGetOrCreateExecutor_ReturnsExistingExecutorWithoutRedeployment() public {
        address first = harness.getOrCreateExecutor(address(this));
        address second = harness.getOrCreateExecutor(address(this));

        assertEq(second, first, "must return the same executor on subsequent calls");
    }

    /// @dev B9 — reverts when no executor exists and plasmaVault is address(0).
    function testGetOrCreateExecutor_RevertsWhenPlasmaVaultIsZeroAndNoExecutorExists() public {
        vm.expectRevert(
            abi.encodeWithSelector(MidasExecutor.MidasExecutorInvalidPlasmaVaultAddress.selector)
        );
        harness.getOrCreateExecutor(address(0));
    }

    /// @dev B7 — does NOT revert when executor already exists even if plasmaVault arg is address(0).
    function testGetOrCreateExecutor_DoesNotRevertWhenPlasmaVaultIsZeroButExecutorExists() public {
        // Create executor with a valid plasmaVault first.
        address existing = harness.getOrCreateExecutor(address(this));

        // Second call with address(0) must NOT revert because the existing executor is returned.
        address returned = harness.getOrCreateExecutor(address(0));

        assertEq(returned, existing, "must return the existing executor without reverting");
    }

    /// @dev B7, B8 — first plasmaVault wins; second call with a different plasmaVault is ignored.
    function testGetOrCreateExecutor_StoredExecutorPersistsAcrossMultipleCalls() public {
        address plasmaVault1 = address(0x1111);
        address plasmaVault2 = address(0x2222);

        address first = harness.getOrCreateExecutor(plasmaVault1);
        address second = harness.getOrCreateExecutor(plasmaVault2);

        // Both calls must return the same executor.
        assertEq(second, first, "must return the same executor regardless of plasmaVault_ on second call");

        // The executor records the first plasmaVault, not the second.
        assertEq(
            MidasExecutor(first).PLASMA_VAULT(),
            plasmaVault1,
            "PLASMA_VAULT must be the first caller's address"
        );
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 4.5  Storage Isolation (B2, B4)
    // ══════════════════════════════════════════════════════════════════════════

    /// @dev B2, B4 — two separate harness instances have independent ERC-7201 storage.
    function testStorageIsolation_DifferentHarnessesHaveIndependentStorage() public {
        MidasExecutorStorageLibHarness harness2 = new MidasExecutorStorageLibHarness();

        harness.setExecutor(address(0xAAAA));

        assertEq(harness.getExecutor(), address(0xAAAA), "harness1 must hold the stored address");
        assertEq(harness2.getExecutor(), address(0), "harness2 must be unaffected");
    }

    // ══════════════════════════════════════════════════════════════════════════
    // 4.6  Fuzz Tests (B2, B3, B4, B5, B6, B7, B8)
    // ══════════════════════════════════════════════════════════════════════════

    /// @dev B2, B3, B4, B5 — set-then-get round-trip holds for all addresses (including address(0)).
    function testFuzz_SetAndGetExecutor_RoundTrips(address executor_) public {
        harness.setExecutor(executor_);
        assertEq(harness.getExecutor(), executor_, "round-trip: getExecutor must return the set address");
    }

    /// @dev B6 — last-write-wins for any pair of distinct addresses.
    function testFuzz_SetExecutor_OverwriteAlwaysWins(address first_, address second_) public {
        vm.assume(first_ != second_);

        harness.setExecutor(first_);
        harness.setExecutor(second_);

        assertEq(harness.getExecutor(), second_, "last write must win");
    }

    /// @dev B7, B8 — for any non-zero plasmaVault, getOrCreateExecutor returns a valid executor with correct PLASMA_VAULT.
    function testFuzz_GetOrCreateExecutor_AlwaysReturnsNonZeroForValidInput(address plasmaVault_) public {
        vm.assume(plasmaVault_ != address(0));

        // Deploy a fresh harness per fuzz run to start with empty storage.
        MidasExecutorStorageLibHarness freshHarness = new MidasExecutorStorageLibHarness();

        address returned = freshHarness.getOrCreateExecutor(plasmaVault_);

        assertTrue(returned != address(0), "returned executor must be non-zero");
        assertEq(
            MidasExecutor(returned).PLASMA_VAULT(),
            plasmaVault_,
            "PLASMA_VAULT must match the provided plasmaVault_"
        );
    }
}

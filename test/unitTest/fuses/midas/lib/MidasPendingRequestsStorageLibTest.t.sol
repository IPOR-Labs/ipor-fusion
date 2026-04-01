// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MidasPendingRequestsStorageLib} from "contracts/fuses/midas/lib/MidasPendingRequestsStorageLib.sol";
import {MidasPendingRequestsStorageLibHarness} from "./mocks/MidasPendingRequestsStorageLibHarness.sol";

/// @title MidasPendingRequestsStorageLibTest
/// @notice Unit tests for MidasPendingRequestsStorageLib - 100% branch coverage target
/// @dev Uses a harness contract to expose internal library functions.
///      Each test deploys a fresh harness so ERC-7201 storage starts clean.
contract MidasPendingRequestsStorageLibTest is Test {
    // ============ Constants ============

    address constant VAULT_A = address(0xA);
    address constant VAULT_B = address(0xB);
    address constant VAULT_C = address(0xC);
    uint256 constant REQUEST_1 = 1;
    uint256 constant REQUEST_2 = 2;
    uint256 constant REQUEST_3 = 3;
    uint256 constant REQUEST_MAX = type(uint256).max;
    uint256 constant REQUEST_ZERO = 0;

    // ============ State Variables ============

    MidasPendingRequestsStorageLibHarness harness;

    // ============ Setup ============

    function setUp() public {
        harness = new MidasPendingRequestsStorageLibHarness();
        vm.label(VAULT_A, "VAULT_A");
        vm.label(VAULT_B, "VAULT_B");
        vm.label(VAULT_C, "VAULT_C");
        vm.label(address(harness), "Harness");
    }

    // ============ Section 1: addPendingDeposit ============

    /// @dev Branches: B-AD3 (first request adds vault), B-AD5 (empty loop)
    function testAddPendingDeposit_FirstRequestForVault() public {
        // When
        harness.addPendingDeposit(VAULT_A, REQUEST_1);

        // Then: vault tracked, request stored
        uint256[] memory ids = harness.getPendingDepositsForVault(VAULT_A);
        assertEq(ids.length, 1, "Should have 1 pending deposit");
        assertEq(ids[0], REQUEST_1, "Request ID should be REQUEST_1");

        (address[] memory vaults, uint256[][] memory requestIds) = harness.getPendingDeposits();
        assertEq(vaults.length, 1, "Should have 1 tracked vault");
        assertEq(vaults[0], VAULT_A, "Vault should be VAULT_A");
        assertEq(requestIds[0].length, 1, "Should have 1 request ID for vault");
        assertEq(requestIds[0][0], REQUEST_1, "Request ID in getPendingDeposits should match");

        assertTrue(harness.isDepositPending(VAULT_A, REQUEST_1), "REQUEST_1 should be pending");
    }

    /// @dev Branches: B-AD2 (no match, continue loop), B-AD4 (vault already tracked)
    function testAddPendingDeposit_SecondRequestForSameVault() public {
        // Given
        harness.addPendingDeposit(VAULT_A, REQUEST_1);

        // When
        harness.addPendingDeposit(VAULT_A, REQUEST_2);

        // Then: vault not duplicated, both requests tracked
        uint256[] memory ids = harness.getPendingDepositsForVault(VAULT_A);
        assertEq(ids.length, 2, "Should have 2 pending deposits");
        assertEq(ids[0], REQUEST_1, "First request should be REQUEST_1");
        assertEq(ids[1], REQUEST_2, "Second request should be REQUEST_2");

        (address[] memory vaults, ) = harness.getPendingDeposits();
        assertEq(vaults.length, 1, "Vault array length should still be 1 (not duplicated)");

        assertTrue(harness.isDepositPending(VAULT_A, REQUEST_1), "REQUEST_1 should be pending");
        assertTrue(harness.isDepositPending(VAULT_A, REQUEST_2), "REQUEST_2 should be pending");
    }

    /// @dev Branches: B-AD3 (twice), B-AD5 (twice)
    function testAddPendingDeposit_RequestsForDifferentVaults() public {
        // When
        harness.addPendingDeposit(VAULT_A, REQUEST_1);
        harness.addPendingDeposit(VAULT_B, REQUEST_2);

        // Then: both vaults independently tracked
        (address[] memory vaults, uint256[][] memory requestIds) = harness.getPendingDeposits();
        assertEq(vaults.length, 2, "Should have 2 tracked vaults");

        uint256[] memory idsA = harness.getPendingDepositsForVault(VAULT_A);
        assertEq(idsA.length, 1, "VAULT_A should have 1 request");
        assertEq(idsA[0], REQUEST_1, "VAULT_A should have REQUEST_1");

        uint256[] memory idsB = harness.getPendingDepositsForVault(VAULT_B);
        assertEq(idsB.length, 1, "VAULT_B should have 1 request");
        assertEq(idsB[0], REQUEST_2, "VAULT_B should have REQUEST_2");

        // Verify requestIds mapping in getPendingDeposits corresponds correctly
        assertEq(requestIds.length, 2, "Request IDs array should have 2 entries");
    }

    /// @dev Branch: B-AD1 (duplicate found, revert)
    function testAddPendingDeposit_RevertOnDuplicateRequestId() public {
        // Given
        harness.addPendingDeposit(VAULT_A, REQUEST_1);

        // When / Then
        vm.expectRevert(
            abi.encodeWithSelector(
                MidasPendingRequestsStorageLib.MidasPendingStorageRequestAlreadyExists.selector,
                VAULT_A,
                REQUEST_1
            )
        );
        harness.addPendingDeposit(VAULT_A, REQUEST_1);
    }

    /// @dev Branches: B-AD3, B-AD5 — same requestId across different vaults must not conflict
    function testAddPendingDeposit_SameRequestIdDifferentVaults() public {
        // Given
        harness.addPendingDeposit(VAULT_A, REQUEST_1);

        // When: same request ID for a different vault — should succeed
        harness.addPendingDeposit(VAULT_B, REQUEST_1);

        // Then: both vaults independently hold REQUEST_1
        assertTrue(harness.isDepositPending(VAULT_A, REQUEST_1), "VAULT_A should have REQUEST_1 pending");
        assertTrue(harness.isDepositPending(VAULT_B, REQUEST_1), "VAULT_B should have REQUEST_1 pending");
    }

    /// @dev Branches: B-AD1, B-AD2 — duplicate detected at non-first position (loop iteration)
    function testAddPendingDeposit_DuplicateCheckWithMultipleExistingIds() public {
        // Given: three requests for VAULT_A
        harness.addPendingDeposit(VAULT_A, REQUEST_1);
        harness.addPendingDeposit(VAULT_A, REQUEST_2);
        harness.addPendingDeposit(VAULT_A, REQUEST_3);

        // When: add duplicate of the last element
        vm.expectRevert(
            abi.encodeWithSelector(
                MidasPendingRequestsStorageLib.MidasPendingStorageRequestAlreadyExists.selector,
                VAULT_A,
                REQUEST_3
            )
        );
        harness.addPendingDeposit(VAULT_A, REQUEST_3);
    }

    /// @dev Branches: B-AD3, B-AD5 — zero is a valid uint256 request ID
    function testAddPendingDeposit_WithZeroRequestId() public {
        // When
        harness.addPendingDeposit(VAULT_A, REQUEST_ZERO);

        // Then
        assertTrue(harness.isDepositPending(VAULT_A, REQUEST_ZERO), "Zero request ID should be pending");
        uint256[] memory ids = harness.getPendingDepositsForVault(VAULT_A);
        assertEq(ids.length, 1, "Should have 1 pending deposit");
        assertEq(ids[0], REQUEST_ZERO, "Request ID should be zero");
    }

    /// @dev Branches: B-AD3, B-AD5 — boundary: type(uint256).max as request ID
    function testAddPendingDeposit_WithMaxRequestId() public {
        // When
        harness.addPendingDeposit(VAULT_A, REQUEST_MAX);

        // Then
        assertTrue(harness.isDepositPending(VAULT_A, REQUEST_MAX), "Max request ID should be pending");
        uint256[] memory ids = harness.getPendingDepositsForVault(VAULT_A);
        assertEq(ids.length, 1, "Should have 1 pending deposit");
        assertEq(ids[0], REQUEST_MAX, "Request ID should be max uint256");
    }

    // ============ Section 2: removePendingDeposit ============

    /// @dev Branches: B-RD1 (found, swap-and-pop), B-RD4 (!found=false), B-RD5 (ids empty, remove vault), B-RDV1 (vault found in array)
    function testRemovePendingDeposit_SingleRequestRemovesVault() public {
        // Given
        harness.addPendingDeposit(VAULT_A, REQUEST_1);

        // When
        harness.removePendingDeposit(VAULT_A, REQUEST_1);

        // Then: request removed, vault removed from tracked list
        uint256[] memory ids = harness.getPendingDepositsForVault(VAULT_A);
        assertEq(ids.length, 0, "VAULT_A should have no pending deposits");

        (address[] memory vaults, ) = harness.getPendingDeposits();
        assertEq(vaults.length, 0, "Deposit vaults array should be empty");

        assertFalse(harness.isDepositPending(VAULT_A, REQUEST_1), "REQUEST_1 should no longer be pending");
    }

    /// @dev Branches: B-RD1, B-RD4, B-RD6 (vault still has requests, not removed)
    function testRemovePendingDeposit_OneOfMultipleRequests_VaultRetained() public {
        // Given
        harness.addPendingDeposit(VAULT_A, REQUEST_1);
        harness.addPendingDeposit(VAULT_A, REQUEST_2);

        // When
        harness.removePendingDeposit(VAULT_A, REQUEST_1);

        // Then: swap-and-pop replaces REQUEST_1 with REQUEST_2
        uint256[] memory ids = harness.getPendingDepositsForVault(VAULT_A);
        assertEq(ids.length, 1, "Should have 1 remaining deposit");
        assertEq(ids[0], REQUEST_2, "REQUEST_2 should remain (swapped to index 0)");

        (address[] memory vaults, ) = harness.getPendingDeposits();
        assertEq(vaults.length, 1, "VAULT_A should still be tracked");

        assertFalse(harness.isDepositPending(VAULT_A, REQUEST_1), "REQUEST_1 should be removed");
        assertTrue(harness.isDepositPending(VAULT_A, REQUEST_2), "REQUEST_2 should still be pending");
    }

    /// @dev Branches: B-RD1, B-RD2, B-RD4, B-RD6 — removing the last element (swap with itself then pop)
    function testRemovePendingDeposit_RemoveLastElement_NoSwapNeeded() public {
        // Given
        harness.addPendingDeposit(VAULT_A, REQUEST_1);
        harness.addPendingDeposit(VAULT_A, REQUEST_2);
        harness.addPendingDeposit(VAULT_A, REQUEST_3);

        // When: remove last element
        harness.removePendingDeposit(VAULT_A, REQUEST_3);

        // Then
        uint256[] memory ids = harness.getPendingDepositsForVault(VAULT_A);
        assertEq(ids.length, 2, "Should have 2 remaining deposits");
        assertEq(ids[0], REQUEST_1, "REQUEST_1 should remain at index 0");
        assertEq(ids[1], REQUEST_2, "REQUEST_2 should remain at index 1");
    }

    /// @dev Branches: B-RD1, B-RD2, B-RD4, B-RD6 — swap-and-pop places last element at removed index
    function testRemovePendingDeposit_RemoveMiddleElement_SwapAndPop() public {
        // Given
        harness.addPendingDeposit(VAULT_A, REQUEST_1);
        harness.addPendingDeposit(VAULT_A, REQUEST_2);
        harness.addPendingDeposit(VAULT_A, REQUEST_3);

        // When: remove middle element
        harness.removePendingDeposit(VAULT_A, REQUEST_2);

        // Then: REQUEST_3 (last) is swapped into index 1
        uint256[] memory ids = harness.getPendingDepositsForVault(VAULT_A);
        assertEq(ids.length, 2, "Should have 2 remaining deposits");
        assertEq(ids[0], REQUEST_1, "REQUEST_1 should remain at index 0");
        assertEq(ids[1], REQUEST_3, "REQUEST_3 should be swapped to index 1");

        assertFalse(harness.isDepositPending(VAULT_A, REQUEST_2), "REQUEST_2 should be removed");
        assertTrue(harness.isDepositPending(VAULT_A, REQUEST_3), "REQUEST_3 should still be pending");
    }

    /// @dev Branch: B-RD3 (!found, revert) — request ID doesn't exist for vault
    function testRemovePendingDeposit_RevertOnRequestNotFound() public {
        // Given
        harness.addPendingDeposit(VAULT_A, REQUEST_1);

        // When / Then
        vm.expectRevert(
            abi.encodeWithSelector(
                MidasPendingRequestsStorageLib.MidasPendingStorageRequestNotFound.selector,
                VAULT_A,
                REQUEST_2
            )
        );
        harness.removePendingDeposit(VAULT_A, REQUEST_2);
    }

    /// @dev Branch: B-RD3 — remove from completely empty storage
    function testRemovePendingDeposit_RevertOnEmptyArray() public {
        // When / Then: clean state, no requests added
        vm.expectRevert(
            abi.encodeWithSelector(
                MidasPendingRequestsStorageLib.MidasPendingStorageRequestNotFound.selector,
                VAULT_A,
                REQUEST_1
            )
        );
        harness.removePendingDeposit(VAULT_A, REQUEST_1);
    }

    /// @dev Branches: B-RD1, B-RD5, B-RDV1, B-RDV2 — removing from one vault doesn't affect another
    function testRemovePendingDeposit_RemoveLastRequestFromVault_OtherVaultUnaffected() public {
        // Given
        harness.addPendingDeposit(VAULT_A, REQUEST_1);
        harness.addPendingDeposit(VAULT_B, REQUEST_2);

        // When
        harness.removePendingDeposit(VAULT_A, REQUEST_1);

        // Then: only VAULT_B remains
        (address[] memory vaults, ) = harness.getPendingDeposits();
        assertEq(vaults.length, 1, "Only VAULT_B should remain");
        assertEq(vaults[0], VAULT_B, "Remaining vault should be VAULT_B");

        uint256[] memory idsB = harness.getPendingDepositsForVault(VAULT_B);
        assertEq(idsB.length, 1, "VAULT_B should still have 1 request");
        assertEq(idsB[0], REQUEST_2, "VAULT_B should still have REQUEST_2");
    }

    /// @dev Branches: B-RDV1, B-RDV2 — tests _removeDepositVault swap-and-pop with 3 vaults
    function testRemovePendingDeposit_VaultSwapAndPop_MultipleVaults() public {
        // Given: 3 vaults tracked (A at index 0, B at index 1, C at index 2)
        harness.addPendingDeposit(VAULT_A, REQUEST_1);
        harness.addPendingDeposit(VAULT_B, REQUEST_2);
        harness.addPendingDeposit(VAULT_C, REQUEST_3);

        // When: remove VAULT_A (first vault), triggers vault swap-and-pop
        harness.removePendingDeposit(VAULT_A, REQUEST_1);

        // Then: VAULT_C swapped to index 0, VAULT_B stays at index 1
        (address[] memory vaults, uint256[][] memory requestIds) = harness.getPendingDeposits();
        assertEq(vaults.length, 2, "Should have 2 remaining vaults");

        // Find VAULT_B and VAULT_C in result (order may vary due to swap-and-pop)
        bool foundB;
        bool foundC;
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i] == VAULT_B) {
                foundB = true;
                assertEq(requestIds[i][0], REQUEST_2, "VAULT_B should still have REQUEST_2");
            }
            if (vaults[i] == VAULT_C) {
                foundC = true;
                assertEq(requestIds[i][0], REQUEST_3, "VAULT_C should still have REQUEST_3");
            }
        }
        assertTrue(foundB, "VAULT_B should be in the vaults array");
        assertTrue(foundC, "VAULT_C should be in the vaults array");

        // VAULT_A should be gone
        assertFalse(harness.isDepositPending(VAULT_A, REQUEST_1), "VAULT_A REQUEST_1 should be removed");
    }

    // ============ Section 3: getPendingDeposits ============

    /// @dev Branch: B-GD1 — empty state returns empty arrays
    function testGetPendingDeposits_Empty() public view {
        // When
        (address[] memory vaults, uint256[][] memory requestIds) = harness.getPendingDeposits();

        // Then
        assertEq(vaults.length, 0, "Vaults array should be empty");
        assertEq(requestIds.length, 0, "RequestIds array should be empty");
    }

    /// @dev Branch: B-GD2 — multiple vaults and requests returned correctly
    function testGetPendingDeposits_MultipleVaultsMultipleRequests() public {
        // Given
        harness.addPendingDeposit(VAULT_A, REQUEST_1);
        harness.addPendingDeposit(VAULT_A, REQUEST_2);
        harness.addPendingDeposit(VAULT_B, REQUEST_3);

        // When
        (address[] memory vaults, uint256[][] memory requestIds) = harness.getPendingDeposits();

        // Then
        assertEq(vaults.length, 2, "Should have 2 vaults");

        // Find VAULT_A index
        uint256 indexA = vaults[0] == VAULT_A ? 0 : 1;
        uint256 indexB = indexA == 0 ? 1 : 0;

        assertEq(vaults[indexA], VAULT_A, "VAULT_A should be in vaults");
        assertEq(requestIds[indexA].length, 2, "VAULT_A should have 2 requests");
        assertEq(requestIds[indexA][0], REQUEST_1, "VAULT_A first request should be REQUEST_1");
        assertEq(requestIds[indexA][1], REQUEST_2, "VAULT_A second request should be REQUEST_2");

        assertEq(vaults[indexB], VAULT_B, "VAULT_B should be in vaults");
        assertEq(requestIds[indexB].length, 1, "VAULT_B should have 1 request");
        assertEq(requestIds[indexB][0], REQUEST_3, "VAULT_B request should be REQUEST_3");
    }

    // ============ Section 4: getPendingDepositsForVault ============

    /// @dev Branch: B-GDV2 — untracked vault returns empty array
    function testGetPendingDepositsForVault_NonExistentVault() public view {
        // When
        uint256[] memory ids = harness.getPendingDepositsForVault(VAULT_A);

        // Then
        assertEq(ids.length, 0, "Untracked vault should return empty array");
    }

    /// @dev Branch: B-GDV1 — vault with requests returns correct array
    function testGetPendingDepositsForVault_WithRequests() public {
        // Given
        harness.addPendingDeposit(VAULT_A, REQUEST_1);
        harness.addPendingDeposit(VAULT_A, REQUEST_2);

        // When
        uint256[] memory ids = harness.getPendingDepositsForVault(VAULT_A);

        // Then
        assertEq(ids.length, 2, "Should return 2 request IDs");
        assertEq(ids[0], REQUEST_1, "First request ID should be REQUEST_1");
        assertEq(ids[1], REQUEST_2, "Second request ID should be REQUEST_2");
    }

    // ============ Section 5: isDepositPending ============

    /// @dev Branch: B-IDP1 — request exists, returns true
    function testIsDepositPending_ExistingRequest() public {
        // Given
        harness.addPendingDeposit(VAULT_A, REQUEST_1);

        // When / Then
        assertTrue(harness.isDepositPending(VAULT_A, REQUEST_1), "REQUEST_1 should be pending for VAULT_A");
    }

    /// @dev Branch: B-IDP2 — loop completes without match
    function testIsDepositPending_NonExistingRequestId() public {
        // Given
        harness.addPendingDeposit(VAULT_A, REQUEST_1);

        // When / Then
        assertFalse(harness.isDepositPending(VAULT_A, REQUEST_2), "REQUEST_2 should not be pending for VAULT_A");
    }

    /// @dev Branch: B-IDP3 — empty storage, loop skipped
    function testIsDepositPending_EmptyStorage() public view {
        // When / Then: clean state
        assertFalse(harness.isDepositPending(VAULT_A, REQUEST_1), "Should return false on empty storage");
    }

    /// @dev Branches: B-IDP2/B-IDP3 — request exists for VAULT_A but checked on VAULT_B
    function testIsDepositPending_WrongVault() public {
        // Given
        harness.addPendingDeposit(VAULT_A, REQUEST_1);

        // When / Then: REQUEST_1 belongs to VAULT_A, not VAULT_B
        assertFalse(harness.isDepositPending(VAULT_B, REQUEST_1), "REQUEST_1 should not be pending for VAULT_B");
    }

    /// @dev Branch: B-IDP1 after B-IDP2 iterations — loop finds match at last position
    function testIsDepositPending_FoundAtLastPosition() public {
        // Given: three requests, check last one
        harness.addPendingDeposit(VAULT_A, REQUEST_1);
        harness.addPendingDeposit(VAULT_A, REQUEST_2);
        harness.addPendingDeposit(VAULT_A, REQUEST_3);

        // When / Then: REQUEST_3 is at index 2 (last), loop must iterate all elements
        assertTrue(harness.isDepositPending(VAULT_A, REQUEST_3), "REQUEST_3 at last position should be pending");
    }

    // ============ Section 6: addPendingRedemption ============

    /// @dev Branches: B-AR3 (first request adds vault), B-AR5 (empty loop)
    function testAddPendingRedemption_FirstRequestForVault() public {
        // When
        harness.addPendingRedemption(VAULT_A, REQUEST_1);

        // Then
        uint256[] memory ids = harness.getPendingRedemptionsForVault(VAULT_A);
        assertEq(ids.length, 1, "Should have 1 pending redemption");
        assertEq(ids[0], REQUEST_1, "Request ID should be REQUEST_1");

        (address[] memory vaults, uint256[][] memory requestIds) = harness.getPendingRedemptions();
        assertEq(vaults.length, 1, "Should have 1 tracked redemption vault");
        assertEq(vaults[0], VAULT_A, "Vault should be VAULT_A");
        assertEq(requestIds[0][0], REQUEST_1, "Request ID should match");

        assertTrue(harness.isRedemptionPending(VAULT_A, REQUEST_1), "REQUEST_1 should be pending redemption");
    }

    /// @dev Branches: B-AR2 (no duplicate, continue), B-AR4 (vault already tracked)
    function testAddPendingRedemption_SecondRequestForSameVault() public {
        // Given
        harness.addPendingRedemption(VAULT_A, REQUEST_1);

        // When
        harness.addPendingRedemption(VAULT_A, REQUEST_2);

        // Then
        uint256[] memory ids = harness.getPendingRedemptionsForVault(VAULT_A);
        assertEq(ids.length, 2, "Should have 2 pending redemptions");
        assertEq(ids[0], REQUEST_1, "First request should be REQUEST_1");
        assertEq(ids[1], REQUEST_2, "Second request should be REQUEST_2");

        (address[] memory vaults, ) = harness.getPendingRedemptions();
        assertEq(vaults.length, 1, "Vault array should not have duplicates");
    }

    /// @dev Branches: B-AR3 (twice) — different vaults tracked independently
    function testAddPendingRedemption_RequestsForDifferentVaults() public {
        // When
        harness.addPendingRedemption(VAULT_A, REQUEST_1);
        harness.addPendingRedemption(VAULT_B, REQUEST_2);

        // Then
        (address[] memory vaults, ) = harness.getPendingRedemptions();
        assertEq(vaults.length, 2, "Should track 2 redemption vaults");

        assertTrue(harness.isRedemptionPending(VAULT_A, REQUEST_1), "VAULT_A REQUEST_1 should be pending");
        assertTrue(harness.isRedemptionPending(VAULT_B, REQUEST_2), "VAULT_B REQUEST_2 should be pending");
    }

    /// @dev Branch: B-AR1 (duplicate found, revert)
    function testAddPendingRedemption_RevertOnDuplicate() public {
        // Given
        harness.addPendingRedemption(VAULT_A, REQUEST_1);

        // When / Then
        vm.expectRevert(
            abi.encodeWithSelector(
                MidasPendingRequestsStorageLib.MidasPendingStorageRequestAlreadyExists.selector,
                VAULT_A,
                REQUEST_1
            )
        );
        harness.addPendingRedemption(VAULT_A, REQUEST_1);
    }

    /// @dev Branch: B-AR3 — same request ID across different vaults must not conflict
    function testAddPendingRedemption_SameRequestIdDifferentVaults() public {
        // Given
        harness.addPendingRedemption(VAULT_A, REQUEST_1);

        // When: same request ID for a different vault — should succeed
        harness.addPendingRedemption(VAULT_B, REQUEST_1);

        // Then
        assertTrue(harness.isRedemptionPending(VAULT_A, REQUEST_1), "VAULT_A REQUEST_1 should be pending");
        assertTrue(harness.isRedemptionPending(VAULT_B, REQUEST_1), "VAULT_B REQUEST_1 should be pending");
    }

    /// @dev Branches: B-AR1, B-AR2 — duplicate detected at non-first position
    function testAddPendingRedemption_DuplicateCheckWithMultipleExistingIds() public {
        // Given
        harness.addPendingRedemption(VAULT_A, REQUEST_1);
        harness.addPendingRedemption(VAULT_A, REQUEST_2);
        harness.addPendingRedemption(VAULT_A, REQUEST_3);

        // When: add duplicate of middle element
        vm.expectRevert(
            abi.encodeWithSelector(
                MidasPendingRequestsStorageLib.MidasPendingStorageRequestAlreadyExists.selector,
                VAULT_A,
                REQUEST_2
            )
        );
        harness.addPendingRedemption(VAULT_A, REQUEST_2);
    }

    // ============ Section 7: removePendingRedemption ============

    /// @dev Branches: B-RR1, B-RR4, B-RR5, B-RRV1
    function testRemovePendingRedemption_SingleRequestRemovesVault() public {
        // Given
        harness.addPendingRedemption(VAULT_A, REQUEST_1);

        // When
        harness.removePendingRedemption(VAULT_A, REQUEST_1);

        // Then
        uint256[] memory ids = harness.getPendingRedemptionsForVault(VAULT_A);
        assertEq(ids.length, 0, "VAULT_A should have no pending redemptions");

        (address[] memory vaults, ) = harness.getPendingRedemptions();
        assertEq(vaults.length, 0, "Redemption vaults array should be empty");

        assertFalse(harness.isRedemptionPending(VAULT_A, REQUEST_1), "REQUEST_1 should no longer be pending");
    }

    /// @dev Branches: B-RR1, B-RR4, B-RR6 — vault retained when other requests remain
    function testRemovePendingRedemption_OneOfMultiple_VaultRetained() public {
        // Given
        harness.addPendingRedemption(VAULT_A, REQUEST_1);
        harness.addPendingRedemption(VAULT_A, REQUEST_2);

        // When
        harness.removePendingRedemption(VAULT_A, REQUEST_1);

        // Then: REQUEST_2 swapped to index 0
        uint256[] memory ids = harness.getPendingRedemptionsForVault(VAULT_A);
        assertEq(ids.length, 1, "Should have 1 remaining redemption");
        assertEq(ids[0], REQUEST_2, "REQUEST_2 should remain");

        (address[] memory vaults, ) = harness.getPendingRedemptions();
        assertEq(vaults.length, 1, "VAULT_A should still be tracked");
    }

    /// @dev Branches: B-RR1, B-RR2, B-RR4, B-RR6 — swap-and-pop middle element
    function testRemovePendingRedemption_RemoveMiddleElement_SwapAndPop() public {
        // Given
        harness.addPendingRedemption(VAULT_A, REQUEST_1);
        harness.addPendingRedemption(VAULT_A, REQUEST_2);
        harness.addPendingRedemption(VAULT_A, REQUEST_3);

        // When
        harness.removePendingRedemption(VAULT_A, REQUEST_2);

        // Then: REQUEST_3 swapped to index 1
        uint256[] memory ids = harness.getPendingRedemptionsForVault(VAULT_A);
        assertEq(ids.length, 2, "Should have 2 remaining redemptions");
        assertEq(ids[0], REQUEST_1, "REQUEST_1 should remain at index 0");
        assertEq(ids[1], REQUEST_3, "REQUEST_3 should be swapped to index 1");
    }

    /// @dev Branch: B-RR3 — request not found
    function testRemovePendingRedemption_RevertOnNotFound() public {
        // Given
        harness.addPendingRedemption(VAULT_A, REQUEST_1);

        // When / Then
        vm.expectRevert(
            abi.encodeWithSelector(
                MidasPendingRequestsStorageLib.MidasPendingStorageRequestNotFound.selector,
                VAULT_A,
                REQUEST_2
            )
        );
        harness.removePendingRedemption(VAULT_A, REQUEST_2);
    }

    /// @dev Branch: B-RR3 — remove from empty storage
    function testRemovePendingRedemption_RevertOnEmptyArray() public {
        // When / Then
        vm.expectRevert(
            abi.encodeWithSelector(
                MidasPendingRequestsStorageLib.MidasPendingStorageRequestNotFound.selector,
                VAULT_A,
                REQUEST_1
            )
        );
        harness.removePendingRedemption(VAULT_A, REQUEST_1);
    }

    /// @dev Branches: B-RR5, B-RRV1 — removing last request from one vault doesn't affect another
    function testRemovePendingRedemption_RemoveLastRequest_OtherVaultUnaffected() public {
        // Given
        harness.addPendingRedemption(VAULT_A, REQUEST_1);
        harness.addPendingRedemption(VAULT_B, REQUEST_2);

        // When
        harness.removePendingRedemption(VAULT_A, REQUEST_1);

        // Then: only VAULT_B remains
        (address[] memory vaults, ) = harness.getPendingRedemptions();
        assertEq(vaults.length, 1, "Only VAULT_B should remain");
        assertEq(vaults[0], VAULT_B, "Remaining vault should be VAULT_B");

        uint256[] memory idsB = harness.getPendingRedemptionsForVault(VAULT_B);
        assertEq(idsB.length, 1, "VAULT_B should still have REQUEST_2");
        assertEq(idsB[0], REQUEST_2, "VAULT_B request should be REQUEST_2");
    }

    /// @dev Branches: B-RRV1, B-RRV2 — _removeRedemptionVault swap-and-pop with 3 vaults
    function testRemovePendingRedemption_VaultSwapAndPop_MultipleVaults() public {
        // Given: 3 vaults tracked (A at index 0, B at index 1, C at index 2)
        harness.addPendingRedemption(VAULT_A, REQUEST_1);
        harness.addPendingRedemption(VAULT_B, REQUEST_2);
        harness.addPendingRedemption(VAULT_C, REQUEST_3);

        // When: remove VAULT_A (first vault)
        harness.removePendingRedemption(VAULT_A, REQUEST_1);

        // Then: VAULT_C swapped to index 0, VAULT_B stays at index 1
        (address[] memory vaults, uint256[][] memory requestIds) = harness.getPendingRedemptions();
        assertEq(vaults.length, 2, "Should have 2 remaining vaults");

        bool foundB;
        bool foundC;
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i] == VAULT_B) {
                foundB = true;
                assertEq(requestIds[i][0], REQUEST_2, "VAULT_B should have REQUEST_2");
            }
            if (vaults[i] == VAULT_C) {
                foundC = true;
                assertEq(requestIds[i][0], REQUEST_3, "VAULT_C should have REQUEST_3");
            }
        }
        assertTrue(foundB, "VAULT_B should be in the vaults array");
        assertTrue(foundC, "VAULT_C should be in the vaults array");
    }

    // ============ Section 8: getPendingRedemptions ============

    /// @dev Branch: B-GR1 — empty state
    function testGetPendingRedemptions_Empty() public view {
        // When
        (address[] memory vaults, uint256[][] memory requestIds) = harness.getPendingRedemptions();

        // Then
        assertEq(vaults.length, 0, "Vaults array should be empty");
        assertEq(requestIds.length, 0, "RequestIds array should be empty");
    }

    /// @dev Branch: B-GR2 — multiple vaults and requests
    function testGetPendingRedemptions_MultipleVaultsMultipleRequests() public {
        // Given
        harness.addPendingRedemption(VAULT_A, REQUEST_1);
        harness.addPendingRedemption(VAULT_A, REQUEST_2);
        harness.addPendingRedemption(VAULT_B, REQUEST_3);

        // When
        (address[] memory vaults, uint256[][] memory requestIds) = harness.getPendingRedemptions();

        // Then
        assertEq(vaults.length, 2, "Should have 2 redemption vaults");

        uint256 indexA = vaults[0] == VAULT_A ? 0 : 1;
        uint256 indexB = indexA == 0 ? 1 : 0;

        assertEq(vaults[indexA], VAULT_A, "VAULT_A should be tracked");
        assertEq(requestIds[indexA].length, 2, "VAULT_A should have 2 redemptions");
        assertEq(requestIds[indexA][0], REQUEST_1, "VAULT_A first redemption should be REQUEST_1");
        assertEq(requestIds[indexA][1], REQUEST_2, "VAULT_A second redemption should be REQUEST_2");

        assertEq(vaults[indexB], VAULT_B, "VAULT_B should be tracked");
        assertEq(requestIds[indexB].length, 1, "VAULT_B should have 1 redemption");
        assertEq(requestIds[indexB][0], REQUEST_3, "VAULT_B redemption should be REQUEST_3");
    }

    // ============ Section 9: getPendingRedemptionsForVault ============

    /// @dev Branch: B-GRV2 — untracked vault returns empty array
    function testGetPendingRedemptionsForVault_NonExistent() public view {
        // When
        uint256[] memory ids = harness.getPendingRedemptionsForVault(VAULT_A);

        // Then
        assertEq(ids.length, 0, "Untracked vault should return empty array");
    }

    /// @dev Branch: B-GRV1 — vault with requests
    function testGetPendingRedemptionsForVault_WithRequests() public {
        // Given
        harness.addPendingRedemption(VAULT_A, REQUEST_1);
        harness.addPendingRedemption(VAULT_A, REQUEST_2);

        // When
        uint256[] memory ids = harness.getPendingRedemptionsForVault(VAULT_A);

        // Then
        assertEq(ids.length, 2, "Should have 2 redemption request IDs");
        assertEq(ids[0], REQUEST_1, "First should be REQUEST_1");
        assertEq(ids[1], REQUEST_2, "Second should be REQUEST_2");
    }

    // ============ Section 10: isRedemptionPending ============

    /// @dev Branch: B-IRP1 — request exists
    function testIsRedemptionPending_ExistingRequest() public {
        // Given
        harness.addPendingRedemption(VAULT_A, REQUEST_1);

        // When / Then
        assertTrue(harness.isRedemptionPending(VAULT_A, REQUEST_1), "REQUEST_1 should be pending redemption");
    }

    /// @dev Branch: B-IRP2 — loop completes without match
    function testIsRedemptionPending_NonExistingRequestId() public {
        // Given
        harness.addPendingRedemption(VAULT_A, REQUEST_1);

        // When / Then
        assertFalse(harness.isRedemptionPending(VAULT_A, REQUEST_2), "REQUEST_2 should not be pending redemption");
    }

    /// @dev Branch: B-IRP3 — empty storage
    function testIsRedemptionPending_EmptyStorage() public view {
        // When / Then
        assertFalse(harness.isRedemptionPending(VAULT_A, REQUEST_1), "Should return false on empty storage");
    }

    /// @dev Branch: B-IRP3 — request exists for VAULT_A but checked on VAULT_B
    function testIsRedemptionPending_WrongVault() public {
        // Given
        harness.addPendingRedemption(VAULT_A, REQUEST_1);

        // When / Then
        assertFalse(harness.isRedemptionPending(VAULT_B, REQUEST_1), "REQUEST_1 should not be pending for VAULT_B");
    }

    /// @dev Branch: B-IRP1 after iterations — match found at last position
    function testIsRedemptionPending_FoundAtLastPosition() public {
        // Given
        harness.addPendingRedemption(VAULT_A, REQUEST_1);
        harness.addPendingRedemption(VAULT_A, REQUEST_2);
        harness.addPendingRedemption(VAULT_A, REQUEST_3);

        // When / Then: REQUEST_3 at index 2 (last)
        assertTrue(harness.isRedemptionPending(VAULT_A, REQUEST_3), "REQUEST_3 at last position should be pending");
    }

    // ============ Section 11: Cross-Type Isolation Tests ============

    /// @dev Deposit and redemption use independent ERC-7201 storage slots
    function testDepositAndRedemption_IndependentStorage() public {
        // When: same requestId used as both deposit and redemption for same vault
        harness.addPendingDeposit(VAULT_A, REQUEST_1);
        harness.addPendingRedemption(VAULT_A, REQUEST_1);

        // Then: both are independently tracked
        assertTrue(harness.isDepositPending(VAULT_A, REQUEST_1), "REQUEST_1 should be pending deposit");
        assertTrue(harness.isRedemptionPending(VAULT_A, REQUEST_1), "REQUEST_1 should be pending redemption");

        // Remove deposit — should not affect redemption
        harness.removePendingDeposit(VAULT_A, REQUEST_1);
        assertFalse(harness.isDepositPending(VAULT_A, REQUEST_1), "REQUEST_1 deposit should be removed");
        assertTrue(harness.isRedemptionPending(VAULT_A, REQUEST_1), "REQUEST_1 redemption should be unaffected");

        // Remove redemption — should succeed
        harness.removePendingRedemption(VAULT_A, REQUEST_1);
        assertFalse(harness.isRedemptionPending(VAULT_A, REQUEST_1), "REQUEST_1 redemption should be removed");
    }

    /// @dev Removing deposit does not affect redemption storage
    function testRemoveDeposit_DoesNotAffectRedemption() public {
        // Given
        harness.addPendingDeposit(VAULT_A, REQUEST_1);
        harness.addPendingRedemption(VAULT_A, REQUEST_1);

        // When
        harness.removePendingDeposit(VAULT_A, REQUEST_1);

        // Then: deposit gone, redemption untouched
        assertFalse(harness.isDepositPending(VAULT_A, REQUEST_1), "Deposit should be removed");
        assertTrue(harness.isRedemptionPending(VAULT_A, REQUEST_1), "Redemption should be untouched");

        (address[] memory redemptionVaults, ) = harness.getPendingRedemptions();
        assertEq(redemptionVaults.length, 1, "VAULT_A should still be in redemption vaults");
        assertEq(redemptionVaults[0], VAULT_A, "VAULT_A should remain in redemption tracking");
    }

    /// @dev Removing redemption does not affect deposit storage
    function testRemoveRedemption_DoesNotAffectDeposit() public {
        // Given
        harness.addPendingDeposit(VAULT_A, REQUEST_1);
        harness.addPendingRedemption(VAULT_A, REQUEST_1);

        // When
        harness.removePendingRedemption(VAULT_A, REQUEST_1);

        // Then: redemption gone, deposit untouched
        assertFalse(harness.isRedemptionPending(VAULT_A, REQUEST_1), "Redemption should be removed");
        assertTrue(harness.isDepositPending(VAULT_A, REQUEST_1), "Deposit should be untouched");

        (address[] memory depositVaults, ) = harness.getPendingDeposits();
        assertEq(depositVaults.length, 1, "VAULT_A should still be in deposit vaults");
    }

    // ============ Boundary Value Tests ============

    /// @dev B.1 — zero request ID for deposit: full lifecycle (store, retrieve, remove)
    function testAddPendingDeposit_RequestIdZero() public {
        // When: add zero
        harness.addPendingDeposit(VAULT_A, REQUEST_ZERO);

        // Then: stored
        assertTrue(harness.isDepositPending(VAULT_A, REQUEST_ZERO), "Zero request ID should be stored");
        uint256[] memory ids = harness.getPendingDepositsForVault(VAULT_A);
        assertEq(ids[0], REQUEST_ZERO, "Returned request ID should be zero");

        // And: removable
        harness.removePendingDeposit(VAULT_A, REQUEST_ZERO);
        assertFalse(harness.isDepositPending(VAULT_A, REQUEST_ZERO), "Zero request ID should be removable");
    }

    /// @dev B.2 — max uint256 request ID for deposit: full lifecycle
    function testAddPendingDeposit_RequestIdMaxUint256() public {
        // When
        harness.addPendingDeposit(VAULT_A, REQUEST_MAX);

        // Then: stored
        assertTrue(harness.isDepositPending(VAULT_A, REQUEST_MAX), "Max request ID should be stored");
        uint256[] memory ids = harness.getPendingDepositsForVault(VAULT_A);
        assertEq(ids[0], REQUEST_MAX, "Returned request ID should be max uint256");

        // And: removable
        harness.removePendingDeposit(VAULT_A, REQUEST_MAX);
        assertFalse(harness.isDepositPending(VAULT_A, REQUEST_MAX), "Max request ID should be removable");
    }

    /// @dev B.3 — address(0) as vault: library applies no address validation
    function testAddPendingDeposit_VaultAddressZero() public {
        // When
        harness.addPendingDeposit(address(0), REQUEST_1);

        // Then: stored without revert
        assertTrue(harness.isDepositPending(address(0), REQUEST_1), "address(0) vault should be valid");
        uint256[] memory ids = harness.getPendingDepositsForVault(address(0));
        assertEq(ids.length, 1, "address(0) vault should have 1 request");
    }

    /// @dev B.4 — zero request ID for redemption: full lifecycle
    function testAddPendingRedemption_RequestIdZero() public {
        // When
        harness.addPendingRedemption(VAULT_A, REQUEST_ZERO);

        // Then: stored
        assertTrue(harness.isRedemptionPending(VAULT_A, REQUEST_ZERO), "Zero redemption request ID should be stored");

        // And: removable
        harness.removePendingRedemption(VAULT_A, REQUEST_ZERO);
        assertFalse(harness.isRedemptionPending(VAULT_A, REQUEST_ZERO), "Zero redemption request ID should be removable");
    }

    /// @dev B.5 — max uint256 request ID for redemption: full lifecycle
    function testAddPendingRedemption_RequestIdMaxUint256() public {
        // When
        harness.addPendingRedemption(VAULT_A, REQUEST_MAX);

        // Then: stored
        assertTrue(harness.isRedemptionPending(VAULT_A, REQUEST_MAX), "Max redemption request ID should be stored");

        // And: removable
        harness.removePendingRedemption(VAULT_A, REQUEST_MAX);
        assertFalse(harness.isRedemptionPending(VAULT_A, REQUEST_MAX), "Max redemption request ID should be removable");
    }

    // ============ Fuzz Tests ============

    /// @dev Fuzz 1: add then remove deposit is a clean roundtrip
    function testFuzz_AddAndRemoveDeposit_Roundtrip(address vault, uint256 requestId) public {
        vm.assume(vault != address(0));

        vm.label(vault, "FuzzVault");

        // Add
        harness.addPendingDeposit(vault, requestId);

        // Verify added
        assertTrue(harness.isDepositPending(vault, requestId), "Request should be pending after add");
        uint256[] memory ids = harness.getPendingDepositsForVault(vault);
        assertEq(ids.length, 1, "Vault should have exactly 1 request after add");
        assertEq(ids[0], requestId, "Request ID should match fuzz input");

        // Remove
        harness.removePendingDeposit(vault, requestId);

        // Verify removed
        assertFalse(harness.isDepositPending(vault, requestId), "Request should not be pending after remove");
        uint256[] memory idsAfter = harness.getPendingDepositsForVault(vault);
        assertEq(idsAfter.length, 0, "Vault should have 0 requests after remove");

        (address[] memory vaults, ) = harness.getPendingDeposits();
        assertEq(vaults.length, 0, "No vaults should be tracked after remove");
    }

    /// @dev Fuzz 2: add then remove redemption is a clean roundtrip
    function testFuzz_AddAndRemoveRedemption_Roundtrip(address vault, uint256 requestId) public {
        vm.assume(vault != address(0));

        vm.label(vault, "FuzzVault");

        // Add
        harness.addPendingRedemption(vault, requestId);

        // Verify added
        assertTrue(harness.isRedemptionPending(vault, requestId), "Redemption should be pending after add");
        uint256[] memory ids = harness.getPendingRedemptionsForVault(vault);
        assertEq(ids.length, 1, "Vault should have 1 redemption after add");

        // Remove
        harness.removePendingRedemption(vault, requestId);

        // Verify removed
        assertFalse(harness.isRedemptionPending(vault, requestId), "Redemption should not be pending after remove");
        (address[] memory vaults, ) = harness.getPendingRedemptions();
        assertEq(vaults.length, 0, "No vaults should be tracked after remove");
    }

    /// @dev Fuzz 3: two different requests for same vault — vault tracked only once
    function testFuzz_AddMultipleDeposits_NoDuplicateVaults(uint256 requestId1, uint256 requestId2) public {
        vm.assume(requestId1 != requestId2);
        address vault = VAULT_A;

        // When
        harness.addPendingDeposit(vault, requestId1);
        harness.addPendingDeposit(vault, requestId2);

        // Then: vault tracked once, 2 requests stored
        (address[] memory vaults, ) = harness.getPendingDeposits();
        assertEq(vaults.length, 1, "Vault should be tracked exactly once");

        uint256[] memory ids = harness.getPendingDepositsForVault(vault);
        assertEq(ids.length, 2, "Should have 2 pending requests");

        assertTrue(harness.isDepositPending(vault, requestId1), "requestId1 should be pending");
        assertTrue(harness.isDepositPending(vault, requestId2), "requestId2 should be pending");
    }

    /// @dev Fuzz 4: adding same deposit twice always reverts with AlreadyExists
    function testFuzz_AddDeposit_DuplicateAlwaysReverts(address vault, uint256 requestId) public {
        vm.assume(vault != address(0));

        // Given: first add succeeds
        harness.addPendingDeposit(vault, requestId);

        // When / Then: second add always reverts
        vm.expectRevert(
            abi.encodeWithSelector(
                MidasPendingRequestsStorageLib.MidasPendingStorageRequestAlreadyExists.selector,
                vault,
                requestId
            )
        );
        harness.addPendingDeposit(vault, requestId);
    }

    /// @dev Fuzz 5: removing non-existent deposit always reverts with NotFound
    function testFuzz_RemoveDeposit_NonExistentAlwaysReverts(address vault, uint256 requestId) public {
        vm.assume(vault != address(0));

        // When / Then: remove from empty storage always reverts
        vm.expectRevert(
            abi.encodeWithSelector(
                MidasPendingRequestsStorageLib.MidasPendingStorageRequestNotFound.selector,
                vault,
                requestId
            )
        );
        harness.removePendingDeposit(vault, requestId);
    }

    /// @dev Fuzz 6: add 5 deposits, remove one at fuzzed index, remaining 4 all still pending
    function testFuzz_SwapAndPop_OrderPreservation(uint8 indexToRemove) public {
        // Bound to valid index range [0, 4]
        indexToRemove = uint8(bound(indexToRemove, 0, 4));

        // Given: 5 requests for VAULT_A
        uint256[5] memory requests = [uint256(1), 2, 3, 4, 5];
        for (uint256 i = 0; i < 5; i++) {
            harness.addPendingDeposit(VAULT_A, requests[i]);
        }

        // When: remove the request at the fuzz-selected index (requestId = index + 1)
        uint256 removedId = requests[indexToRemove];
        harness.removePendingDeposit(VAULT_A, removedId);

        // Then: length is 4
        uint256[] memory ids = harness.getPendingDepositsForVault(VAULT_A);
        assertEq(ids.length, 4, "Should have 4 remaining requests");

        // And: removed request is not found
        assertFalse(harness.isDepositPending(VAULT_A, removedId), "Removed request should not be pending");

        // And: all remaining requests are still found
        for (uint256 i = 0; i < 5; i++) {
            if (requests[i] != removedId) {
                assertTrue(
                    harness.isDepositPending(VAULT_A, requests[i]),
                    "Non-removed request should still be pending"
                );
            }
        }
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TermFinancePendingOffersStorageLibHarness} from "./mocks/TermFinancePendingOffersStorageLibHarness.sol";

/// @title TermFinancePendingOffersStorageLibTest
/// @notice Unit tests for the ERC-7201 pending-offers storage lib. Targets 100% coverage.
contract TermFinancePendingOffersStorageLibTest is Test {
    address internal constant SRV_A = address(0xA);
    address internal constant SRV_B = address(0xB);
    address internal constant SRV_C = address(0xC);
    address internal constant LOCKER_A = address(0xAAAA);
    address internal constant LOCKER_A2 = address(0xAA01);
    address internal constant LOCKER_B = address(0xBBBB);

    bytes32 internal constant ID_1 = bytes32(uint256(0x1));
    bytes32 internal constant ID_2 = bytes32(uint256(0x2));
    bytes32 internal constant ID_3 = bytes32(uint256(0x3));

    TermFinancePendingOffersStorageLibHarness h;

    function setUp() public {
        h = new TermFinancePendingOffersStorageLibHarness();
    }

    // ============ add ============

    function test_add_firstEntry_addsServicerToTopLevel() public {
        h.addPendingOffer(SRV_A, LOCKER_A, ID_1, 1_000e6);

        address[] memory servicers = h.getAllPendingServicers();
        assertEq(servicers.length, 1);
        assertEq(servicers[0], SRV_A);

        (address[] memory offerLockers, bytes32[] memory ids, uint256[] memory amounts) = h
            .getPendingOffersForServicer(SRV_A);
        assertEq(offerLockers.length, 1);
        assertEq(offerLockers[0], LOCKER_A);
        assertEq(ids.length, 1);
        assertEq(ids[0], ID_1);
        assertEq(amounts[0], 1_000e6);
        assertTrue(h.isOfferPending(SRV_A, ID_1));
    }

    function test_add_secondEntrySameServicer_doesNotDuplicateServicer() public {
        h.addPendingOffer(SRV_A, LOCKER_A, ID_1, 1_000e6);
        h.addPendingOffer(SRV_A, LOCKER_A, ID_2, 2_000e6);

        address[] memory servicers = h.getAllPendingServicers();
        assertEq(servicers.length, 1);

        (, bytes32[] memory ids, uint256[] memory amounts) = h.getPendingOffersForServicer(SRV_A);
        assertEq(ids.length, 2);
        assertEq(ids[0], ID_1);
        assertEq(ids[1], ID_2);
        assertEq(amounts[0], 1_000e6);
        assertEq(amounts[1], 2_000e6);
    }

    function test_add_duplicateId_refreshesLockerAndAmount() public {
        h.addPendingOffer(SRV_A, LOCKER_A, ID_1, 1_000e6);
        // Same id, different locker (simulates latest enter wins).
        h.addPendingOffer(SRV_A, LOCKER_A2, ID_1, 9_999);

        (address[] memory offerLockers, bytes32[] memory ids, uint256[] memory amounts) = h
            .getPendingOffersForServicer(SRV_A);
        // Per-id Locker AND amount are refreshed; entry not duplicated. This keeps NAV accurate
        // when the locker returns a colliding id (defensive against bugs / malicious upstream).
        assertEq(offerLockers.length, 1);
        assertEq(offerLockers[0], LOCKER_A2);
        assertEq(ids.length, 1);
        assertEq(amounts[0], 9_999, "amount refreshed on duplicate add");
    }

    function test_add_multipleServicers_allTracked() public {
        h.addPendingOffer(SRV_A, LOCKER_A, ID_1, 100);
        h.addPendingOffer(SRV_B, LOCKER_B, ID_2, 200);
        h.addPendingOffer(SRV_C, LOCKER_A, ID_3, 300);

        address[] memory servicers = h.getAllPendingServicers();
        assertEq(servicers.length, 3);
    }

    // ============ remove ============

    function test_remove_existingId_removesEntry() public {
        h.addPendingOffer(SRV_A, LOCKER_A, ID_1, 1_000e6);

        h.removePendingOfferIfExists(SRV_A, ID_1);

        (, bytes32[] memory ids, ) = h.getPendingOffersForServicer(SRV_A);
        assertEq(ids.length, 0);
        assertFalse(h.isOfferPending(SRV_A, ID_1));
    }

    function test_remove_lastEntryForServicer_removesServicerFromTopLevel() public {
        h.addPendingOffer(SRV_A, LOCKER_A, ID_1, 1);
        h.addPendingOffer(SRV_B, LOCKER_B, ID_2, 2);

        h.removePendingOfferIfExists(SRV_A, ID_1);

        address[] memory servicers = h.getAllPendingServicers();
        assertEq(servicers.length, 1);
        assertEq(servicers[0], SRV_B);

        // Per-id locker storage for SRV_A is empty (all entries removed).
        (address[] memory offerLockers, , ) = h.getPendingOffersForServicer(SRV_A);
        assertEq(offerLockers.length, 0);
    }

    function test_remove_missingId_isNoOp() public {
        // Empty storage — should not revert.
        h.removePendingOfferIfExists(SRV_A, ID_1);

        // With other entries — should not affect them.
        h.addPendingOffer(SRV_A, LOCKER_A, ID_1, 1);
        h.removePendingOfferIfExists(SRV_A, ID_2); // ID_2 not present

        assertTrue(h.isOfferPending(SRV_A, ID_1), "untouched entry remains");
    }

    function test_remove_swapAndPop_preservesIndexConsistency() public {
        // 3 entries; remove the middle one — last should swap into the middle slot.
        h.addPendingOffer(SRV_A, LOCKER_A, ID_1, 100);
        h.addPendingOffer(SRV_A, LOCKER_A, ID_2, 200);
        h.addPendingOffer(SRV_A, LOCKER_A, ID_3, 300);

        h.removePendingOfferIfExists(SRV_A, ID_2);

        (, bytes32[] memory ids, uint256[] memory amounts) = h.getPendingOffersForServicer(SRV_A);
        assertEq(ids.length, 2);
        // After swap-and-pop: ID_1 stays at 0, ID_3 moves into slot 1.
        assertEq(ids[0], ID_1);
        assertEq(amounts[0], 100);
        assertEq(ids[1], ID_3);
        assertEq(amounts[1], 300);

        // Both remaining ids resolvable for further removal.
        assertTrue(h.isOfferPending(SRV_A, ID_1));
        assertTrue(h.isOfferPending(SRV_A, ID_3));
        assertFalse(h.isOfferPending(SRV_A, ID_2));

        // Remove ID_3 (now the last) — covers the no-swap branch.
        h.removePendingOfferIfExists(SRV_A, ID_3);
        (, ids, ) = h.getPendingOffersForServicer(SRV_A);
        assertEq(ids.length, 1);
        assertEq(ids[0], ID_1);
    }

    function test_remove_middleServicer_swapPreservesOthers() public {
        h.addPendingOffer(SRV_A, LOCKER_A, ID_1, 1);
        h.addPendingOffer(SRV_B, LOCKER_B, ID_2, 2);
        h.addPendingOffer(SRV_C, LOCKER_A, ID_3, 3);

        h.removePendingOfferIfExists(SRV_B, ID_2);

        address[] memory servicers = h.getAllPendingServicers();
        assertEq(servicers.length, 2);
        // Swap-and-pop on the top-level: SRV_C moves into SRV_B's slot.
        // We don't assert order strictly; just both A and C present.
        bool foundA;
        bool foundC;
        for (uint256 i; i < servicers.length; ++i) {
            if (servicers[i] == SRV_A) foundA = true;
            if (servicers[i] == SRV_C) foundC = true;
        }
        assertTrue(foundA && foundC);
    }

    function test_reAdd_afterRemove_works() public {
        h.addPendingOffer(SRV_A, LOCKER_A, ID_1, 1_000);
        h.removePendingOfferIfExists(SRV_A, ID_1);
        h.addPendingOffer(SRV_A, LOCKER_A, ID_1, 5_000);

        (, bytes32[] memory ids, uint256[] memory amounts) = h.getPendingOffersForServicer(SRV_A);
        assertEq(ids.length, 1);
        assertEq(amounts[0], 5_000);
    }

    // ============ getters ============

    function test_get_emptyServicer_returnsEmptyArrays() public view {
        (address[] memory offerLockers, bytes32[] memory ids, uint256[] memory amounts) = h
            .getPendingOffersForServicer(SRV_A);
        assertEq(offerLockers.length, 0);
        assertEq(ids.length, 0);
        assertEq(amounts.length, 0);
    }

    function test_get_allPendingServicers_empty_returnsEmptyArray() public view {
        address[] memory servicers = h.getAllPendingServicers();
        assertEq(servicers.length, 0);
    }

    function test_isOfferPending_falseWhenAbsent() public view {
        assertFalse(h.isOfferPending(SRV_A, ID_1));
    }

    // ============ getOfferLocker ============

    function test_getOfferLocker_tracked_returnsBoundLocker() public {
        h.addPendingOffer(SRV_A, LOCKER_A, ID_1, 1_000);
        assertEq(h.getOfferLocker(SRV_A, ID_1), LOCKER_A);
    }

    function test_getOfferLocker_untracked_returnsZero() public view {
        assertEq(h.getOfferLocker(SRV_A, ID_1), address(0));
    }

    // ============ per-id locker binding across auction cycles ============

    /// @notice A single servicer can have pending offers from two
    ///         different OfferLockers (cycle N still live, cycle N+1 fresh). Per-id
    ///         binding must keep them separate so NAV reads `lockedOffer` against the
    ///         correct locker for each id.
    function test_addPendingOffer_acrossCycles_eachIdBindsToOwnLocker() public {
        // Cycle N — older locker.
        h.addPendingOffer(SRV_A, LOCKER_A, ID_1, 1_000);
        // Cycle N+1 — fresh locker, same servicer, different id.
        h.addPendingOffer(SRV_A, LOCKER_A2, ID_2, 5_000);

        (address[] memory lockers, bytes32[] memory ids, uint256[] memory amounts) = h
            .getPendingOffersForServicer(SRV_A);

        assertEq(lockers.length, 2);
        assertEq(ids.length, 2);
        // Ids preserve insertion order (push-only with swap-and-pop on remove).
        assertEq(ids[0], ID_1);
        assertEq(lockers[0], LOCKER_A);
        assertEq(amounts[0], 1_000);
        assertEq(ids[1], ID_2);
        assertEq(lockers[1], LOCKER_A2);
        assertEq(amounts[1], 5_000);

        // And per-id read returns the same:
        assertEq(h.getOfferLocker(SRV_A, ID_1), LOCKER_A);
        assertEq(h.getOfferLocker(SRV_A, ID_2), LOCKER_A2);
    }

    /// @notice Removing one cycle's entry must leave the other cycle's binding intact.
    function test_removePendingOffer_acrossCycles_doesNotAffectOtherCycleBinding() public {
        h.addPendingOffer(SRV_A, LOCKER_A, ID_1, 1_000);
        h.addPendingOffer(SRV_A, LOCKER_A2, ID_2, 5_000);

        h.removePendingOfferIfExists(SRV_A, ID_1);

        (address[] memory lockers, bytes32[] memory ids, ) = h.getPendingOffersForServicer(SRV_A);
        assertEq(lockers.length, 1);
        assertEq(ids[0], ID_2);
        assertEq(lockers[0], LOCKER_A2, "remaining id keeps its bound locker");
    }
}

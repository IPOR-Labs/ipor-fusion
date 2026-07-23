// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TermFinancePendingBidsStorageLibHarness} from "./mocks/TermFinancePendingBidsStorageLibHarness.sol";

/// @title TermFinancePendingBidsStorageLibTest
/// @notice Unit tests for the ERC-7201 pending-bids storage lib. Covers happy paths,
///         swap-and-pop semantics, idempotent removal, parallel collateral arrays,
///         per-id locker binding, multi-servicer isolation, and
///         the (non-)enforcement of the per-servicer cap from the library itself
///         (the cap lives in the fuse).
contract TermFinancePendingBidsStorageLibTest is Test {
    address internal constant SRV_A = address(0xA);
    address internal constant SRV_B = address(0xB);
    address internal constant SRV_C = address(0xC);
    address internal constant LOCKER_A = address(0xAAAA);
    address internal constant LOCKER_A2 = address(0xAA01);
    address internal constant LOCKER_B = address(0xBBBB);

    address internal constant COL_USDC = address(0xC011);
    address internal constant COL_WBTC = address(0xC012);
    address internal constant COL_WETH = address(0xC013);

    bytes32 internal constant ID_1 = bytes32(uint256(0x1));
    bytes32 internal constant ID_2 = bytes32(uint256(0x2));
    bytes32 internal constant ID_3 = bytes32(uint256(0x3));

    TermFinancePendingBidsStorageLibHarness h;

    function setUp() public {
        h = new TermFinancePendingBidsStorageLibHarness();
    }

    // ============ helpers ============

    function _oneTokenOneAmount(
        address token_,
        uint256 amount_
    ) internal pure returns (address[] memory tokens, uint256[] memory amounts) {
        tokens = new address[](1);
        amounts = new uint256[](1);
        tokens[0] = token_;
        amounts[0] = amount_;
    }

    function _emptyCollateral() internal pure returns (address[] memory tokens, uint256[] memory amounts) {
        tokens = new address[](0);
        amounts = new uint256[](0);
    }

    // ============ add — happy path ============

    function test_add_firstEntry_addsServicerToTopLevel() public {
        (address[] memory cTok, uint256[] memory cAmt) = _oneTokenOneAmount(COL_USDC, 100e6);
        h.addPendingBid(SRV_A, LOCKER_A, ID_1, 1_000e6, cTok, cAmt);

        address[] memory servicers = h.getAllPendingServicers();
        assertEq(servicers.length, 1);
        assertEq(servicers[0], SRV_A);

        assertEq(h.length(SRV_A), 1);
        assertTrue(h.isBidPending(SRV_A, ID_1));
        assertEq(h.getBidLocker(SRV_A, ID_1), LOCKER_A);

        (
            address[] memory bidLockers,
            bytes32[] memory ids,
            uint256[] memory amounts,
            address[][] memory cTokens,
            uint256[][] memory cAmounts
        ) = h.getPendingBidsForServicer(SRV_A);
        assertEq(bidLockers.length, 1);
        assertEq(bidLockers[0], LOCKER_A);
        assertEq(ids[0], ID_1);
        assertEq(amounts[0], 1_000e6);
        assertEq(cTokens[0].length, 1);
        assertEq(cTokens[0][0], COL_USDC);
        assertEq(cAmounts[0].length, 1);
        assertEq(cAmounts[0][0], 100e6);
    }

    function test_add_secondEntrySameServicer_doesNotDuplicateServicer() public {
        (address[] memory cT, uint256[] memory cA) = _oneTokenOneAmount(COL_USDC, 100e6);
        h.addPendingBid(SRV_A, LOCKER_A, ID_1, 1_000e6, cT, cA);
        (cT, cA) = _oneTokenOneAmount(COL_WBTC, 200e6);
        h.addPendingBid(SRV_A, LOCKER_A, ID_2, 2_000e6, cT, cA);

        assertEq(h.getAllPendingServicers().length, 1);
        assertEq(h.length(SRV_A), 2);

        (, bytes32[] memory ids, uint256[] memory amounts, address[][] memory cTokens, ) = h.getPendingBidsForServicer(
            SRV_A
        );
        assertEq(ids.length, 2);
        assertEq(ids[0], ID_1);
        assertEq(ids[1], ID_2);
        assertEq(amounts[0], 1_000e6);
        assertEq(amounts[1], 2_000e6);
        assertEq(cTokens[0][0], COL_USDC);
        assertEq(cTokens[1][0], COL_WBTC);
    }

    function test_add_duplicateId_refreshesAllFieldsInPlace() public {
        (address[] memory cT, uint256[] memory cA) = _oneTokenOneAmount(COL_USDC, 100e6);
        h.addPendingBid(SRV_A, LOCKER_A, ID_1, 1_000e6, cT, cA);

        // Same id, different locker, different amount, different collateral mix (2 tokens).
        address[] memory cT2 = new address[](2);
        uint256[] memory cA2 = new uint256[](2);
        cT2[0] = COL_WBTC;
        cT2[1] = COL_WETH;
        cA2[0] = 5e8;
        cA2[1] = 7e18;
        h.addPendingBid(SRV_A, LOCKER_A2, ID_1, 9_999, cT2, cA2);

        // Length unchanged — entry refreshed in place.
        assertEq(h.length(SRV_A), 1);

        (
            address[] memory bidLockers,
            bytes32[] memory ids,
            uint256[] memory amounts,
            address[][] memory cTokens,
            uint256[][] memory cAmounts
        ) = h.getPendingBidsForServicer(SRV_A);
        assertEq(bidLockers.length, 1);
        assertEq(bidLockers[0], LOCKER_A2, "locker refreshed");
        assertEq(ids[0], ID_1);
        assertEq(amounts[0], 9_999, "amount refreshed");
        assertEq(cTokens[0].length, 2, "collateral tokens refreshed");
        assertEq(cTokens[0][0], COL_WBTC);
        assertEq(cTokens[0][1], COL_WETH);
        assertEq(cAmounts[0].length, 2, "collateral amounts refreshed");
        assertEq(cAmounts[0][0], 5e8);
        assertEq(cAmounts[0][1], 7e18);

        // Per-id locker getter reflects refresh.
        assertEq(h.getBidLocker(SRV_A, ID_1), LOCKER_A2);
    }

    function test_add_multipleServicers_allTracked() public {
        (address[] memory cT, uint256[] memory cA) = _oneTokenOneAmount(COL_USDC, 1);
        h.addPendingBid(SRV_A, LOCKER_A, ID_1, 100, cT, cA);
        h.addPendingBid(SRV_B, LOCKER_B, ID_2, 200, cT, cA);
        h.addPendingBid(SRV_C, LOCKER_A, ID_3, 300, cT, cA);

        assertEq(h.getAllPendingServicers().length, 3);
    }

    function test_add_zeroCollateral_storesEmptyArrays() public {
        (address[] memory cT, uint256[] memory cA) = _emptyCollateral();
        h.addPendingBid(SRV_A, LOCKER_A, ID_1, 1_000e6, cT, cA);

        (, , , address[][] memory cTokens, uint256[][] memory cAmounts) = h.getPendingBidsForServicer(SRV_A);
        assertEq(cTokens.length, 1);
        assertEq(cTokens[0].length, 0, "no collateral tokens stored");
        assertEq(cAmounts[0].length, 0, "no collateral amounts stored");
    }

    function test_add_multipleCollateralTokens_parallelArraysPreserved() public {
        address[] memory cT = new address[](3);
        uint256[] memory cA = new uint256[](3);
        cT[0] = COL_USDC;
        cT[1] = COL_WBTC;
        cT[2] = COL_WETH;
        cA[0] = 100e6;
        cA[1] = 5e8;
        cA[2] = 1e18;

        h.addPendingBid(SRV_A, LOCKER_A, ID_1, 1_000e6, cT, cA);

        (, , , address[][] memory cTokens, uint256[][] memory cAmounts) = h.getPendingBidsForServicer(SRV_A);
        assertEq(cTokens[0].length, 3);
        assertEq(cAmounts[0].length, cTokens[0].length, "parallel array length match");
        assertEq(cTokens[0][0], COL_USDC);
        assertEq(cAmounts[0][0], 100e6);
        assertEq(cTokens[0][1], COL_WBTC);
        assertEq(cAmounts[0][1], 5e8);
        assertEq(cTokens[0][2], COL_WETH);
        assertEq(cAmounts[0][2], 1e18);
    }

    // ============ remove ============

    function test_remove_existingId_removesEntry() public {
        (address[] memory cT, uint256[] memory cA) = _oneTokenOneAmount(COL_USDC, 1);
        h.addPendingBid(SRV_A, LOCKER_A, ID_1, 1_000e6, cT, cA);

        h.removePendingBidIfExists(SRV_A, ID_1);

        assertEq(h.length(SRV_A), 0);
        assertFalse(h.isBidPending(SRV_A, ID_1));
        assertEq(h.getBidLocker(SRV_A, ID_1), address(0));
    }

    function test_remove_lastEntryForServicer_removesServicerFromTopLevel() public {
        (address[] memory cT, uint256[] memory cA) = _oneTokenOneAmount(COL_USDC, 1);
        h.addPendingBid(SRV_A, LOCKER_A, ID_1, 1, cT, cA);
        h.addPendingBid(SRV_B, LOCKER_B, ID_2, 2, cT, cA);

        h.removePendingBidIfExists(SRV_A, ID_1);

        address[] memory servicers = h.getAllPendingServicers();
        assertEq(servicers.length, 1);
        assertEq(servicers[0], SRV_B);
    }

    function test_remove_missingId_isNoOp_emptyStorage() public {
        // Empty storage — must not revert and must not allocate state.
        h.removePendingBidIfExists(SRV_A, ID_1);
        assertEq(h.length(SRV_A), 0);
        assertEq(h.getAllPendingServicers().length, 0);
    }

    function test_remove_missingId_isNoOp_nonEmpty() public {
        (address[] memory cT, uint256[] memory cA) = _oneTokenOneAmount(COL_USDC, 1);
        h.addPendingBid(SRV_A, LOCKER_A, ID_1, 1, cT, cA);

        // ID_2 not present — must be a no-op leaving ID_1 in place.
        h.removePendingBidIfExists(SRV_A, ID_2);

        assertEq(h.length(SRV_A), 1);
        assertTrue(h.isBidPending(SRV_A, ID_1));
    }

    function test_remove_swapAndPop_preservesIndexConsistency() public {
        (address[] memory cT, uint256[] memory cA) = _oneTokenOneAmount(COL_USDC, 1);
        h.addPendingBid(SRV_A, LOCKER_A, ID_1, 100, cT, cA);
        h.addPendingBid(SRV_A, LOCKER_A, ID_2, 200, cT, cA);
        h.addPendingBid(SRV_A, LOCKER_A, ID_3, 300, cT, cA);

        // Remove middle — last should swap into the middle slot.
        h.removePendingBidIfExists(SRV_A, ID_2);

        (, bytes32[] memory ids, uint256[] memory amounts, , ) = h.getPendingBidsForServicer(SRV_A);
        assertEq(ids.length, 2);
        assertEq(ids[0], ID_1);
        assertEq(amounts[0], 100);
        assertEq(ids[1], ID_3);
        assertEq(amounts[1], 300);

        assertTrue(h.isBidPending(SRV_A, ID_1));
        assertTrue(h.isBidPending(SRV_A, ID_3));
        assertFalse(h.isBidPending(SRV_A, ID_2));

        // Now remove the last (no-swap branch).
        h.removePendingBidIfExists(SRV_A, ID_3);
        (, ids, , , ) = h.getPendingBidsForServicer(SRV_A);
        assertEq(ids.length, 1);
        assertEq(ids[0], ID_1);
    }

    function test_remove_orderAfterAddAB_removeA_BStillAccessible() public {
        (address[] memory cT, uint256[] memory cA) = _oneTokenOneAmount(COL_USDC, 1);
        h.addPendingBid(SRV_A, LOCKER_A, ID_1, 10, cT, cA);
        h.addPendingBid(SRV_A, LOCKER_A2, ID_2, 20, cT, cA);

        h.removePendingBidIfExists(SRV_A, ID_1);

        assertEq(h.length(SRV_A), 1);
        assertFalse(h.isBidPending(SRV_A, ID_1));
        assertTrue(h.isBidPending(SRV_A, ID_2));
        assertEq(h.getBidLocker(SRV_A, ID_2), LOCKER_A2, "B keeps its locker after A removed");

        (address[] memory lockers, bytes32[] memory ids, uint256[] memory amounts, , ) = h.getPendingBidsForServicer(
            SRV_A
        );
        assertEq(lockers[0], LOCKER_A2);
        assertEq(ids[0], ID_2);
        assertEq(amounts[0], 20);
    }

    function test_remove_middleServicer_swapPreservesOthers() public {
        (address[] memory cT, uint256[] memory cA) = _oneTokenOneAmount(COL_USDC, 1);
        h.addPendingBid(SRV_A, LOCKER_A, ID_1, 1, cT, cA);
        h.addPendingBid(SRV_B, LOCKER_B, ID_2, 2, cT, cA);
        h.addPendingBid(SRV_C, LOCKER_A, ID_3, 3, cT, cA);

        h.removePendingBidIfExists(SRV_B, ID_2);

        address[] memory servicers = h.getAllPendingServicers();
        assertEq(servicers.length, 2);

        bool foundA;
        bool foundC;
        for (uint256 i; i < servicers.length; ++i) {
            if (servicers[i] == SRV_A) foundA = true;
            if (servicers[i] == SRV_C) foundC = true;
        }
        assertTrue(foundA && foundC);
    }

    function test_reAdd_afterRemove_works() public {
        (address[] memory cT, uint256[] memory cA) = _oneTokenOneAmount(COL_USDC, 1);
        h.addPendingBid(SRV_A, LOCKER_A, ID_1, 1_000, cT, cA);
        h.removePendingBidIfExists(SRV_A, ID_1);
        h.addPendingBid(SRV_A, LOCKER_A2, ID_1, 5_000, cT, cA);

        (address[] memory lockers, bytes32[] memory ids, uint256[] memory amounts, , ) = h.getPendingBidsForServicer(
            SRV_A
        );
        assertEq(ids.length, 1);
        assertEq(lockers[0], LOCKER_A2);
        assertEq(amounts[0], 5_000);
    }

    // ============ getters ============

    function test_length_emptyServicer_isZero() public view {
        assertEq(h.length(SRV_A), 0);
    }

    function test_get_emptyServicer_returnsEmptyArrays() public view {
        (
            address[] memory bidLockers,
            bytes32[] memory ids,
            uint256[] memory amounts,
            address[][] memory cTokens,
            uint256[][] memory cAmounts
        ) = h.getPendingBidsForServicer(SRV_A);
        assertEq(bidLockers.length, 0);
        assertEq(ids.length, 0);
        assertEq(amounts.length, 0);
        assertEq(cTokens.length, 0);
        assertEq(cAmounts.length, 0);
    }

    function test_getAllPendingServicers_empty_returnsEmptyArray() public view {
        assertEq(h.getAllPendingServicers().length, 0);
    }

    function test_isBidPending_falseWhenAbsent() public view {
        assertFalse(h.isBidPending(SRV_A, ID_1));
    }

    function test_getBidLocker_tracked_returnsBoundLocker() public {
        (address[] memory cT, uint256[] memory cA) = _oneTokenOneAmount(COL_USDC, 1);
        h.addPendingBid(SRV_A, LOCKER_A, ID_1, 1_000, cT, cA);
        assertEq(h.getBidLocker(SRV_A, ID_1), LOCKER_A);
    }

    function test_getBidLocker_untracked_returnsZero() public view {
        assertEq(h.getBidLocker(SRV_A, ID_1), address(0));
    }

    // ============ per-id locker binding across auction cycles ============

    /// @notice A single servicer can have pending bids from two
    ///         different BidLockers (cycle N still live, cycle N+1 fresh). Per-id
    ///         binding must keep them independent so NAV reads `lockedBid` against
    ///         the correct locker per id.
    function test_addPendingBid_acrossCycles_eachIdBindsToOwnLocker() public {
        (address[] memory cT, uint256[] memory cA) = _oneTokenOneAmount(COL_USDC, 10e6);
        h.addPendingBid(SRV_A, LOCKER_A, ID_1, 1_000, cT, cA);
        (cT, cA) = _oneTokenOneAmount(COL_WBTC, 1e8);
        h.addPendingBid(SRV_A, LOCKER_A2, ID_2, 5_000, cT, cA);

        (
            address[] memory lockers,
            bytes32[] memory ids,
            uint256[] memory amounts,
            address[][] memory cTokens,
            uint256[][] memory cAmounts
        ) = h.getPendingBidsForServicer(SRV_A);

        assertEq(lockers.length, 2);
        // Insertion order preserved (push-only with swap-and-pop on remove).
        assertEq(ids[0], ID_1);
        assertEq(lockers[0], LOCKER_A);
        assertEq(amounts[0], 1_000);
        assertEq(cTokens[0][0], COL_USDC);
        assertEq(cAmounts[0][0], 10e6);

        assertEq(ids[1], ID_2);
        assertEq(lockers[1], LOCKER_A2);
        assertEq(amounts[1], 5_000);
        assertEq(cTokens[1][0], COL_WBTC);
        assertEq(cAmounts[1][0], 1e8);

        // Per-id getter mirrors the per-bid binding.
        assertEq(h.getBidLocker(SRV_A, ID_1), LOCKER_A);
        assertEq(h.getBidLocker(SRV_A, ID_2), LOCKER_A2);
    }

    /// @notice Removing one cycle's entry must leave the other cycle's binding intact.
    function test_removePendingBid_acrossCycles_doesNotAffectOtherCycleBinding() public {
        (address[] memory cT, uint256[] memory cA) = _oneTokenOneAmount(COL_USDC, 10e6);
        h.addPendingBid(SRV_A, LOCKER_A, ID_1, 1_000, cT, cA);
        h.addPendingBid(SRV_A, LOCKER_A2, ID_2, 5_000, cT, cA);

        h.removePendingBidIfExists(SRV_A, ID_1);

        (address[] memory lockers, bytes32[] memory ids, , , ) = h.getPendingBidsForServicer(SRV_A);
        assertEq(lockers.length, 1);
        assertEq(ids[0], ID_2);
        assertEq(lockers[0], LOCKER_A2, "remaining id keeps its bound locker");
        assertEq(h.getBidLocker(SRV_A, ID_2), LOCKER_A2);
    }

    /// @notice Same `bidId` on two DIFFERENT lockers under DIFFERENT servicers — both
    ///         retrievable independently (per-servicer scoping).
    function test_sameBidId_underTwoServicers_isolatedState() public {
        (address[] memory cT, uint256[] memory cA) = _oneTokenOneAmount(COL_USDC, 1);
        h.addPendingBid(SRV_A, LOCKER_A, ID_1, 100, cT, cA);
        h.addPendingBid(SRV_B, LOCKER_B, ID_1, 200, cT, cA);

        assertTrue(h.isBidPending(SRV_A, ID_1));
        assertTrue(h.isBidPending(SRV_B, ID_1));
        assertEq(h.getBidLocker(SRV_A, ID_1), LOCKER_A);
        assertEq(h.getBidLocker(SRV_B, ID_1), LOCKER_B);
        assertEq(h.length(SRV_A), 1);
        assertEq(h.length(SRV_B), 1);

        // Removing from A leaves B intact.
        h.removePendingBidIfExists(SRV_A, ID_1);
        assertFalse(h.isBidPending(SRV_A, ID_1));
        assertTrue(h.isBidPending(SRV_B, ID_1));
        assertEq(h.getBidLocker(SRV_B, ID_1), LOCKER_B);
    }

    // ============ cap edge: library does NOT enforce MAX_PENDING_BIDS_PER_SERVICER ============

    /// @notice The library itself MUST NOT cap insertions — the per-servicer cap is enforced
    ///         by `TermFinanceBidFuse.enter` AFTER the storage write (so the over-cap revert
    ///         atomically rolls back the just-added id). Confirm by inserting MAX_+5 entries
    ///         without revert.
    function test_add_beyondMaxPendingBidsPerServicer_libraryDoesNotEnforceCap() public {
        uint256 max = h.maxPendingBidsPerServicer();
        uint256 toInsert = max + 5;

        (address[] memory cT, uint256[] memory cA) = _oneTokenOneAmount(COL_USDC, 1);
        for (uint256 i; i < toInsert; ++i) {
            bytes32 id = bytes32(uint256(i) + 1);
            h.addPendingBid(SRV_A, LOCKER_A, id, i + 1, cT, cA);
        }

        assertEq(h.length(SRV_A), toInsert, "library accepts beyond cap");
        // Spot check first and last entry.
        assertTrue(h.isBidPending(SRV_A, bytes32(uint256(1))));
        assertTrue(h.isBidPending(SRV_A, bytes32(toInsert)));
    }
}

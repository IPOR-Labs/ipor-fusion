// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Errors} from "contracts/libraries/errors/Errors.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {IExtTermAuctionOfferLocker} from "contracts/fuses/term_finance/ext/IExtTermAuctionOfferLocker.sol";
import {IExtTermAuctionBidLocker} from "contracts/fuses/term_finance/ext/IExtTermAuctionBidLocker.sol";
import {
    TermFinanceCleanupFuse,
    TermFinanceCleanupFuseEnterData
} from "contracts/fuses/term_finance/TermFinanceCleanupFuse.sol";

import {TermFinanceCleanupFuseHarness} from "./mocks/TermFinanceCleanupFuseHarness.sol";
import {MockTermAuctionOfferLocker} from "./mocks/MockTermAuctionOfferLocker.sol";
import {MockTermAuctionBidLocker} from "./mocks/MockTermAuctionBidLocker.sol";

contract TermFinanceCleanupFuseTest is Test {
    uint256 internal constant MARKET_ID = 52;

    /// @dev Canonical WithdrawManager ERC-7201 slot — mirrors `PlasmaVaultStorageLib`'s
    ///      `WITHDRAW_MANAGER` constant (private there). Used by tests to toggle the
    ///      `_assertWithdrawManagerSet()` guard via `vm.store` on the harness address.
    bytes32 internal constant WITHDRAW_MANAGER_SLOT =
        0x465d2ff0062318fe6f4c7e9ac78cfcd70bc86a1d992722875ef83a9770513100;

    /// @dev Sentinel WithdrawManager address — any non-zero value is sufficient for the
    ///      `_assertWithdrawManagerSet()` guard to pass.
    address internal constant WITHDRAW_MANAGER = address(0xCAFE);

    TermFinanceCleanupFuseHarness harness;
    MockTermAuctionOfferLocker offerLocker;
    MockTermAuctionBidLocker bidLocker;
    address servicer;

    function setUp() public {
        harness = new TermFinanceCleanupFuseHarness(MARKET_ID);
        offerLocker = new MockTermAuctionOfferLocker();
        bidLocker = new MockTermAuctionBidLocker();
        servicer = makeAddr("servicer");

        bytes32[] memory subs = new bytes32[](1);
        subs[0] = PlasmaVaultConfigLib.addressToBytes32(servicer);
        harness.setMarketSubstrates(MARKET_ID, subs);

        // Default: WithdrawManager is configured so the gate passes.
        _setWithdrawManager(WITHDRAW_MANAGER);
    }

    // ============ helpers ============

    /// @notice Direct-poke the WithdrawManager slot of the harness so the runtime check
    ///         resolves correctly. Mirrors the `vm.store` pattern in
    ///         `TermFinanceBidFuseTest._setWithdrawManager`.
    function _setWithdrawManager(address manager_) internal {
        vm.store(address(harness), WITHDRAW_MANAGER_SLOT, bytes32(uint256(uint160(manager_))));
    }

    function _emptyIds() internal pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    /// @dev Safe default: `pruneOnLockerRevert: false` — a reverting locker is
    ///      skipped, not pruned.
    function _enterData(
        bytes32[] memory offerIds_,
        bytes32[] memory bidIds_
    ) internal view returns (TermFinanceCleanupFuseEnterData memory) {
        return
            TermFinanceCleanupFuseEnterData({
                servicer: servicer,
                offerIds: offerIds_,
                bidIds: bidIds_,
                pruneOnLockerRevert: false
            });
    }

    /// @dev Force-prune variant: `pruneOnLockerRevert: true` — the operator confirms a dead
    ///      locker and accepts pruning entries whose locker read reverts.
    function _enterDataPrune(
        bytes32[] memory offerIds_,
        bytes32[] memory bidIds_
    ) internal view returns (TermFinanceCleanupFuseEnterData memory) {
        return
            TermFinanceCleanupFuseEnterData({
                servicer: servicer,
                offerIds: offerIds_,
                bidIds: bidIds_,
                pruneOnLockerRevert: true
            });
    }

    function _seedStale(bytes32 id_) internal {
        // amount == 0 → stale.
        offerLocker.setLockedOffer(
            id_,
            IExtTermAuctionOfferLocker.TermAuctionOffer({
                id: id_,
                offeror: address(0),
                offerPriceHash: bytes32(0),
                offerPriceRevealed: 0,
                amount: 0,
                purchaseToken: address(0),
                isRevealed: true
            })
        );
    }

    function _seedActive(bytes32 id_, uint256 amt_) internal {
        offerLocker.setLockedOffer(
            id_,
            IExtTermAuctionOfferLocker.TermAuctionOffer({
                id: id_,
                offeror: address(0),
                offerPriceHash: bytes32(0),
                offerPriceRevealed: 0,
                amount: amt_,
                purchaseToken: address(0),
                isRevealed: false
            })
        );
    }

    function _seedClearedBid(bytes32 id_) internal {
        // bidder == 0 → stale per `_shouldPruneBid`.
        bidLocker.setLockedBid(
            id_,
            IExtTermAuctionBidLocker.TermAuctionBid({
                id: id_,
                bidder: address(0),
                bidPriceHash: bytes32(0),
                bidPriceRevealed: 0,
                amount: 0,
                collateralAmounts: new uint256[](0),
                purchaseToken: address(0),
                collateralTokens: new address[](0),
                isRollover: false,
                rolloverPairOffTermRepoServicer: address(0),
                isRevealed: false
            })
        );
    }

    function _seedZeroAmountBid(bytes32 id_, address bidder_) internal {
        // bidder != 0 BUT amount == 0 → stale per predicate `bidder == 0 || amount == 0`.
        bidLocker.setLockedBid(
            id_,
            IExtTermAuctionBidLocker.TermAuctionBid({
                id: id_,
                bidder: bidder_,
                bidPriceHash: bytes32(0),
                bidPriceRevealed: 0,
                amount: 0,
                collateralAmounts: new uint256[](0),
                purchaseToken: address(0),
                collateralTokens: new address[](0),
                isRollover: false,
                rolloverPairOffTermRepoServicer: address(0),
                isRevealed: false
            })
        );
    }

    function _seedActiveBid(bytes32 id_, address bidder_, uint256 amount_) internal {
        bidLocker.setLockedBid(
            id_,
            IExtTermAuctionBidLocker.TermAuctionBid({
                id: id_,
                bidder: bidder_,
                bidPriceHash: bytes32(0),
                bidPriceRevealed: 0,
                amount: amount_,
                collateralAmounts: new uint256[](0),
                purchaseToken: address(0),
                collateralTokens: new address[](0),
                isRollover: false,
                rolloverPairOffTermRepoServicer: address(0),
                isRevealed: false
            })
        );
    }

    function _addPendingBidEmptyCollateral(address bidLocker_, bytes32 bidId_, uint256 amount_) internal {
        harness.addPendingBid(
            servicer,
            bidLocker_,
            bidId_,
            amount_,
            new address[](0),
            new uint256[](0)
        );
    }

    // ============ constructor ============

    function test_constructor_setsImmutables() public view {
        assertEq(harness.MARKET_ID(), MARKET_ID);
        assertEq(harness.VERSION(), address(harness));
    }

    function test_constructor_revertsOnZeroMarketId() public {
        vm.expectRevert(Errors.WrongValue.selector);
        new TermFinanceCleanupFuseHarness(0);
    }

    /// @notice Regression: constructor MUST NOT contain the WithdrawManager check.
    function testConstructorShouldNotRevertWhenWithdrawManagerIsZero() public {
        // Plain new'ing the harness must succeed even with an empty WITHDRAW_MANAGER slot
        // on the deployer EOA — the gate lives in `enter`, not the constructor.
        TermFinanceCleanupFuseHarness fresh = new TermFinanceCleanupFuseHarness(MARKET_ID);
        assertEq(fresh.MARKET_ID(), MARKET_ID);
        assertEq(fresh.VERSION(), address(fresh));
    }

    // ============ enter — WithdrawManager runtime check ============

    function testCleanupEnterShouldRevertWhenWithdrawManagerIsZero() public {
        _setWithdrawManager(address(0));

        vm.expectRevert(TermFinanceCleanupFuse.TermFinanceCleanupFuseWithdrawManagerRequired.selector);
        harness.enter(_enterData(_emptyIds(), _emptyIds()));
    }

    /// @notice Ordering: WithdrawManager check runs FIRST, before substrate validation.
    ///         With BOTH the WithdrawManager zeroed AND substrates wiped, the revert must
    ///         be the WithdrawManager selector (not Unsupported).
    function testEnterShouldCheckWithdrawManagerBeforeOtherValidation() public {
        _setWithdrawManager(address(0));
        // Wipe substrates too — if substrate guard ran first, we'd see Unsupported.
        bytes32[] memory empty = new bytes32[](0);
        harness.setMarketSubstrates(MARKET_ID, empty);

        vm.expectRevert(TermFinanceCleanupFuse.TermFinanceCleanupFuseWithdrawManagerRequired.selector);
        harness.enter(_enterData(_emptyIds(), _emptyIds()));
    }

    // ============ enter — substrate guard ============

    function test_enter_revertsOnSubstrateNotGranted() public {
        bytes32[] memory empty = new bytes32[](0);
        harness.setMarketSubstrates(MARKET_ID, empty);

        vm.expectRevert(
            abi.encodeWithSelector(TermFinanceCleanupFuse.TermFinanceCleanupFuseUnsupportedMarket.selector, servicer)
        );
        harness.enter(_enterData(_emptyIds(), _emptyIds()));
    }

    // ============ enter — empty storage ============

    function test_enter_emptyStorage_emitsZeroRemovedAndReturns() public {
        // Assert full event payload — empty storage emits `offersRemoved = 0`
        // AND `bidsRemoved = 0`.
        vm.expectEmit(true, true, true, true);
        emit TermFinanceCleanupFuse.TermFinanceCleanupExecuted(address(harness), servicer, 0, 0);
        harness.enter(_enterData(_emptyIds(), _emptyIds()));
    }

    // ============ enter — scan-all (empty offerIds input) ============

    function test_enter_scanAll_prunesStale_keepsActive() public {
        bytes32 staleId = bytes32(uint256(0x1));
        bytes32 activeId = bytes32(uint256(0x2));
        _seedStale(staleId);
        _seedActive(activeId, 1_000_000);

        harness.addPendingOffer(servicer, address(offerLocker), staleId, 500_000);
        harness.addPendingOffer(servicer, address(offerLocker), activeId, 1_000_000);

        // Assert full event payload — exactly one stale entry pruned.
        vm.expectEmit(true, true, true, true);
        emit TermFinanceCleanupFuse.TermFinanceCleanupExecuted(address(harness), servicer, 1, 0);
        harness.enter(_enterData(_emptyIds(), _emptyIds()));

        assertFalse(harness.isOfferPending(servicer, staleId), "stale pruned");
        assertTrue(harness.isOfferPending(servicer, activeId), "active kept");
    }

    /// @dev With the force-prune opt-in (`pruneOnLockerRevert: true`), a reverting
    ///      locker IS pruned and emits `TermFinanceCleanupPrunedOnRevert`.
    function test_enter_scanAll_lockerReverts_pruneOptIn_prunesAndEmitsRevertEvent() public {
        bytes32 id = bytes32(uint256(0x1));
        harness.addPendingOffer(servicer, address(offerLocker), id, 500_000);
        offerLocker.setLockedOfferReverts(true);

        vm.expectEmit(true, true, true, true);
        emit TermFinanceCleanupFuse.TermFinanceCleanupPrunedOnRevert(address(harness), servicer, id);
        harness.enter(_enterDataPrune(_emptyIds(), _emptyIds()));

        assertFalse(harness.isOfferPending(servicer, id), "force-prune opt-in -> pruned");
    }

    /// @dev SAFE DEFAULT: with `pruneOnLockerRevert: false` a reverting locker is
    ///      KEPT (a transient pause must not erase a live offer from NAV) and emits
    ///      `TermFinanceCleanupSkippedOnRevert`.
    function test_enter_scanAll_lockerReverts_defaultSkips_keepsAndEmitsSkipEvent() public {
        bytes32 id = bytes32(uint256(0x1));
        harness.addPendingOffer(servicer, address(offerLocker), id, 500_000);
        offerLocker.setLockedOfferReverts(true);

        vm.expectEmit(true, true, true, true);
        emit TermFinanceCleanupFuse.TermFinanceCleanupSkippedOnRevert(address(harness), servicer, id);
        harness.enter(_enterData(_emptyIds(), _emptyIds()));

        assertTrue(harness.isOfferPending(servicer, id), "default -> live offer kept on revert");
    }

    function test_enter_selective_lockerReverts_pruneOptIn_prunesAndEmitsRevertEvent() public {
        bytes32 id = bytes32(uint256(0x1));
        harness.addPendingOffer(servicer, address(offerLocker), id, 500_000);
        offerLocker.setLockedOfferReverts(true);

        bytes32[] memory targets = new bytes32[](1);
        targets[0] = id;
        vm.expectEmit(true, true, true, true);
        emit TermFinanceCleanupFuse.TermFinanceCleanupPrunedOnRevert(address(harness), servicer, id);
        harness.enter(_enterDataPrune(targets, _emptyIds()));

        assertFalse(harness.isOfferPending(servicer, id));
    }

    function test_enter_selective_lockerReverts_defaultSkips_keepsAndEmitsSkipEvent() public {
        bytes32 id = bytes32(uint256(0x1));
        harness.addPendingOffer(servicer, address(offerLocker), id, 500_000);
        offerLocker.setLockedOfferReverts(true);

        bytes32[] memory targets = new bytes32[](1);
        targets[0] = id;
        vm.expectEmit(true, true, true, true);
        emit TermFinanceCleanupFuse.TermFinanceCleanupSkippedOnRevert(address(harness), servicer, id);
        harness.enter(_enterData(targets, _emptyIds()));

        assertTrue(harness.isOfferPending(servicer, id), "default -> live offer kept on revert");
    }

    function test_enter_scanAll_allStale_servicerRemovedFromTopLevel() public {
        bytes32 id = bytes32(uint256(0x1));
        _seedStale(id);
        harness.addPendingOffer(servicer, address(offerLocker), id, 500_000);

        harness.enter(_enterData(_emptyIds(), _emptyIds()));

        (, bytes32[] memory got, ) = harness.getPendingOffersForServicer(servicer);
        assertEq(got.length, 0, "all entries pruned");
    }

    // ============ enter — selective (offerIds supplied) ============

    function test_enter_selective_onlyPrunesSuppliedStaleIds() public {
        bytes32 stale1 = bytes32(uint256(0x1));
        bytes32 stale2 = bytes32(uint256(0x2));
        _seedStale(stale1);
        _seedStale(stale2);

        harness.addPendingOffer(servicer, address(offerLocker), stale1, 100);
        harness.addPendingOffer(servicer, address(offerLocker), stale2, 200);

        bytes32[] memory targets = new bytes32[](1);
        targets[0] = stale1;
        harness.enter(_enterData(targets, _emptyIds()));

        assertFalse(harness.isOfferPending(servicer, stale1));
        assertTrue(harness.isOfferPending(servicer, stale2), "selective: untouched");
    }

    function test_enter_selective_ignoresIdsNotInStorage() public {
        bytes32 id = bytes32(uint256(0x1));
        bytes32 ghost = bytes32(uint256(0xDEAD));
        _seedStale(id);
        harness.addPendingOffer(servicer, address(offerLocker), id, 100);

        bytes32[] memory targets = new bytes32[](2);
        targets[0] = id;
        targets[1] = ghost;
        harness.enter(_enterData(targets, _emptyIds()));

        assertFalse(harness.isOfferPending(servicer, id));
        assertFalse(harness.isOfferPending(servicer, ghost), "ghost never tracked");
    }

    function test_enter_selective_keepsActiveEvenIfRequested() public {
        bytes32 id = bytes32(uint256(0x1));
        _seedActive(id, 1_000_000);
        harness.addPendingOffer(servicer, address(offerLocker), id, 1_000_000);

        bytes32[] memory targets = new bytes32[](1);
        targets[0] = id;
        harness.enter(_enterData(targets, _emptyIds()));

        assertTrue(harness.isOfferPending(servicer, id), "active not pruned");
    }

    // ============ idempotency ============

    function test_enter_idempotent_secondCallNoOp() public {
        bytes32 id = bytes32(uint256(0x1));
        _seedStale(id);
        harness.addPendingOffer(servicer, address(offerLocker), id, 100);

        harness.enter(_enterData(_emptyIds(), _emptyIds()));
        // Second call — storage already empty.
        harness.enter(_enterData(_emptyIds(), _emptyIds()));
    }

    // ============ defensive: zero locker in storage ============

    /// @notice Defensive branch. Production write paths reject zero-locker via
    ///         `OfferFuse._assertOfferLockerPaired`, but `_pruneStored` still needs to drop
    ///         entries whose stored locker is zero (e.g. from a future writer that bypasses
    ///         the guard) without staticcall-reverting on `lockedOffer(address(0))`.
    function test_enter_scanAll_zeroLockerInStorage_isPrunedAndEmitsOnRevert() public {
        bytes32 zeroLockerId = bytes32(uint256(0xC0DE));
        // Direct storage write via harness, bypassing the OfferFuse guards.
        harness.addPendingOffer(servicer, address(0), zeroLockerId, 1_000);

        harness.enter(_enterData(_emptyIds(), _emptyIds()));

        assertFalse(harness.isOfferPending(servicer, zeroLockerId), "zero-locker entry pruned");
    }

    // ============================================================================
    // Pending bids cleanup (Phase 3B extension)
    // ============================================================================

    // ---------- bid pruning: happy path ----------

    /// @notice Pending bid is in storage; `lockedBid` returns the cleared (zero)
    ///         struct (bidder == address(0)). The cleanup must remove the bid entry.
    function testCleanupFuseRemovesPendingBidPostClearing() public {
        bytes32 bidId = bytes32(uint256(0xB1));
        _seedClearedBid(bidId); // bidder == 0 → stale
        _addPendingBidEmptyCollateral(address(bidLocker), bidId, 1_000_000);

        // Assert full event payload — bidsRemoved == 1.
        vm.expectEmit(true, true, true, true);
        emit TermFinanceCleanupFuse.TermFinanceCleanupExecuted(address(harness), servicer, 0, 1);
        harness.enter(_enterData(_emptyIds(), _emptyIds()));

        assertFalse(harness.isBidPending(servicer, bidId), "cleared bid pruned");
    }

    function testCleanupShouldRemoveMultipleBidsInOneCall() public {
        bytes32 b1 = bytes32(uint256(0xB1));
        bytes32 b2 = bytes32(uint256(0xB2));
        bytes32 b3 = bytes32(uint256(0xB3));
        _seedClearedBid(b1);
        _seedClearedBid(b2);
        _seedClearedBid(b3);

        _addPendingBidEmptyCollateral(address(bidLocker), b1, 100);
        _addPendingBidEmptyCollateral(address(bidLocker), b2, 200);
        _addPendingBidEmptyCollateral(address(bidLocker), b3, 300);

        vm.expectEmit(true, true, true, true);
        emit TermFinanceCleanupFuse.TermFinanceCleanupExecuted(address(harness), servicer, 0, 3);
        harness.enter(_enterData(_emptyIds(), _emptyIds()));

        assertFalse(harness.isBidPending(servicer, b1), "b1 pruned");
        assertFalse(harness.isBidPending(servicer, b2), "b2 pruned");
        assertFalse(harness.isBidPending(servicer, b3), "b3 pruned");
        assertEq(harness.pendingBidsLength(servicer), 0, "all bids gone");
    }

    // ---------- bid pruning: predicate _shouldPruneBid ----------

    /// @notice Predicate: live bid (bidder != 0 AND amount != 0) MUST NOT be pruned.
    function testCleanupShouldNotRemoveBidIfStillLive() public {
        bytes32 bidId = bytes32(uint256(0xB1));
        _seedActiveBid(bidId, makeAddr("bidder"), 1_000_000);
        _addPendingBidEmptyCollateral(address(bidLocker), bidId, 1_000_000);

        vm.expectEmit(true, true, true, true);
        emit TermFinanceCleanupFuse.TermFinanceCleanupExecuted(address(harness), servicer, 0, 0);
        harness.enter(_enterData(_emptyIds(), _emptyIds()));

        assertTrue(harness.isBidPending(servicer, bidId), "live bid kept");
    }

    /// @notice Predicate: `bidder != 0 AND amount == 0` → still stale. Covers the
    ///         second leg of `bidder == 0 || amount == 0`.
    function testCleanupShouldRemoveBidWhenAmountIsZero() public {
        bytes32 bidId = bytes32(uint256(0xB1));
        // Non-zero bidder + zero amount — stale via the OR predicate.
        _seedZeroAmountBid(bidId, makeAddr("bidder"));
        _addPendingBidEmptyCollateral(address(bidLocker), bidId, 1_000_000);

        vm.expectEmit(true, true, true, true);
        emit TermFinanceCleanupFuse.TermFinanceCleanupExecuted(address(harness), servicer, 0, 1);
        harness.enter(_enterData(_emptyIds(), _emptyIds()));

        assertFalse(harness.isBidPending(servicer, bidId), "zero-amount bid pruned");
    }

    /// @notice Bid locker reverts on `lockedBid` (paused / upgraded proxy). With the
    ///         force-prune opt-in the entry is pruned + emits `TermFinanceCleanupPrunedBidOnRevert`.
    function testCleanupBidLockerReverts_pruneOptIn_prunesAndEmits() public {
        bytes32 bidId = bytes32(uint256(0xB1));
        _addPendingBidEmptyCollateral(address(bidLocker), bidId, 1_000_000);
        bidLocker.setLockedBidReverts(true);

        vm.expectEmit(true, true, true, true);
        emit TermFinanceCleanupFuse.TermFinanceCleanupPrunedBidOnRevert(address(harness), servicer, bidId);
        harness.enter(_enterDataPrune(_emptyIds(), _emptyIds()));

        assertFalse(harness.isBidPending(servicer, bidId), "force-prune opt-in -> bid pruned");
    }

    /// @notice SAFE DEFAULT: a reverting bid locker keeps the entry (transient
    ///         pause must not erase a live bid from NAV) + emits `TermFinanceCleanupSkippedBidOnRevert`.
    function testCleanupBidLockerReverts_defaultSkips_keepsAndEmitsSkip() public {
        bytes32 bidId = bytes32(uint256(0xB1));
        _addPendingBidEmptyCollateral(address(bidLocker), bidId, 1_000_000);
        bidLocker.setLockedBidReverts(true);

        vm.expectEmit(true, true, true, true);
        emit TermFinanceCleanupFuse.TermFinanceCleanupSkippedBidOnRevert(address(harness), servicer, bidId);
        harness.enter(_enterData(_emptyIds(), _emptyIds()));

        assertTrue(harness.isBidPending(servicer, bidId), "default -> live bid kept on revert");
    }

    // ---------- selective bid pruning ----------

    function testCleanupSelectiveBidsOnlyPrunesSuppliedStaleIds() public {
        bytes32 stale1 = bytes32(uint256(0xB1));
        bytes32 stale2 = bytes32(uint256(0xB2));
        _seedClearedBid(stale1);
        _seedClearedBid(stale2);

        _addPendingBidEmptyCollateral(address(bidLocker), stale1, 100);
        _addPendingBidEmptyCollateral(address(bidLocker), stale2, 200);

        bytes32[] memory targets = new bytes32[](1);
        targets[0] = stale1;
        harness.enter(_enterData(_emptyIds(), targets));

        assertFalse(harness.isBidPending(servicer, stale1), "selective: stale1 pruned");
        assertTrue(harness.isBidPending(servicer, stale2), "selective: stale2 untouched");
    }

    function testCleanupSelectiveBidsIgnoresIdsNotInStorage() public {
        bytes32 bidId = bytes32(uint256(0xB1));
        bytes32 ghost = bytes32(uint256(0xDEAD));
        _seedClearedBid(bidId);
        _addPendingBidEmptyCollateral(address(bidLocker), bidId, 100);

        bytes32[] memory targets = new bytes32[](2);
        targets[0] = bidId;
        targets[1] = ghost;
        harness.enter(_enterData(_emptyIds(), targets));

        assertFalse(harness.isBidPending(servicer, bidId), "tracked stale pruned");
        assertFalse(harness.isBidPending(servicer, ghost), "ghost never tracked");
    }

    function testCleanupSelectiveBidsKeepsActiveEvenIfRequested() public {
        bytes32 bidId = bytes32(uint256(0xB1));
        _seedActiveBid(bidId, makeAddr("bidder"), 500_000);
        _addPendingBidEmptyCollateral(address(bidLocker), bidId, 500_000);

        bytes32[] memory targets = new bytes32[](1);
        targets[0] = bidId;
        harness.enter(_enterData(_emptyIds(), targets));

        assertTrue(harness.isBidPending(servicer, bidId), "active not pruned");
    }

    function testCleanupSelectiveBidsLockerReverts_pruneOptIn_prunesAndEmits() public {
        bytes32 bidId = bytes32(uint256(0xB1));
        _addPendingBidEmptyCollateral(address(bidLocker), bidId, 500_000);
        bidLocker.setLockedBidReverts(true);

        bytes32[] memory targets = new bytes32[](1);
        targets[0] = bidId;
        vm.expectEmit(true, true, true, true);
        emit TermFinanceCleanupFuse.TermFinanceCleanupPrunedBidOnRevert(address(harness), servicer, bidId);
        harness.enter(_enterDataPrune(_emptyIds(), targets));

        assertFalse(harness.isBidPending(servicer, bidId));
    }

    function testCleanupSelectiveBidsLockerReverts_defaultSkips_keepsAndEmitsSkip() public {
        bytes32 bidId = bytes32(uint256(0xB1));
        _addPendingBidEmptyCollateral(address(bidLocker), bidId, 500_000);
        bidLocker.setLockedBidReverts(true);

        bytes32[] memory targets = new bytes32[](1);
        targets[0] = bidId;
        vm.expectEmit(true, true, true, true);
        emit TermFinanceCleanupFuse.TermFinanceCleanupSkippedBidOnRevert(address(harness), servicer, bidId);
        harness.enter(_enterData(_emptyIds(), targets));

        assertTrue(harness.isBidPending(servicer, bidId), "default -> live bid kept on revert");
    }

    /// @notice Defensive: bid entry with a zero locker (would never come from BidFuse, but
    ///         still has to be pruneable). Mirrors the offer-side zero-locker test.
    function testCleanupScanAllZeroBidLockerInStorageIsPrunedAndEmitsOnRevert() public {
        bytes32 zeroLockerBidId = bytes32(uint256(0xBE));
        // Direct storage write via harness, bypassing the BidFuse guards.
        _addPendingBidEmptyCollateral(address(0), zeroLockerBidId, 1_000);

        vm.expectEmit(true, true, true, true);
        emit TermFinanceCleanupFuse.TermFinanceCleanupPrunedBidOnRevert(
            address(harness),
            servicer,
            zeroLockerBidId
        );
        harness.enter(_enterData(_emptyIds(), _emptyIds()));

        assertFalse(harness.isBidPending(servicer, zeroLockerBidId), "zero-locker bid pruned");
    }

    // ---------- combined offer + bid cleanup ----------

    /// @notice Combined leg: `data.offerIds` non-empty AND `data.bidIds` non-empty in the
    ///         scan-all variant (both empty inputs → both legs sweep all stored entries).
    function testCleanupShouldRemoveBothOffersAndBidsInOneCall() public {
        bytes32 offerId = bytes32(uint256(0x10));
        bytes32 bidId = bytes32(uint256(0xB1));
        _seedStale(offerId);
        _seedClearedBid(bidId);

        harness.addPendingOffer(servicer, address(offerLocker), offerId, 500_000);
        _addPendingBidEmptyCollateral(address(bidLocker), bidId, 1_000_000);

        harness.enter(_enterData(_emptyIds(), _emptyIds()));

        assertFalse(harness.isOfferPending(servicer, offerId), "offer pruned");
        assertFalse(harness.isBidPending(servicer, bidId), "bid pruned");
    }

    /// @notice Event must carry BOTH counts (offersRemoved AND bidsRemoved).
    function testCleanupExecutedEventCarriesBothCounts() public {
        bytes32 o1 = bytes32(uint256(0x10));
        bytes32 o2 = bytes32(uint256(0x11));
        bytes32 b1 = bytes32(uint256(0xB1));
        bytes32 b2 = bytes32(uint256(0xB2));
        bytes32 b3 = bytes32(uint256(0xB3));
        _seedStale(o1);
        _seedStale(o2);
        _seedClearedBid(b1);
        _seedClearedBid(b2);
        _seedClearedBid(b3);

        harness.addPendingOffer(servicer, address(offerLocker), o1, 100);
        harness.addPendingOffer(servicer, address(offerLocker), o2, 200);
        _addPendingBidEmptyCollateral(address(bidLocker), b1, 100);
        _addPendingBidEmptyCollateral(address(bidLocker), b2, 200);
        _addPendingBidEmptyCollateral(address(bidLocker), b3, 300);

        vm.expectEmit(true, true, true, true);
        emit TermFinanceCleanupFuse.TermFinanceCleanupExecuted(address(harness), servicer, 2, 3);
        harness.enter(_enterData(_emptyIds(), _emptyIds()));
    }

    /// @notice Combined selective: targeted offerIds AND bidIds inputs work in tandem.
    function testCleanupCombinedSelectivePrunesBothTargetedSets() public {
        bytes32 staleOffer = bytes32(uint256(0x10));
        bytes32 activeOffer = bytes32(uint256(0x11));
        bytes32 staleBid = bytes32(uint256(0xB1));
        bytes32 activeBid = bytes32(uint256(0xB2));

        _seedStale(staleOffer);
        _seedActive(activeOffer, 1_000_000);
        _seedClearedBid(staleBid);
        _seedActiveBid(activeBid, makeAddr("bidder"), 500_000);

        harness.addPendingOffer(servicer, address(offerLocker), staleOffer, 100);
        harness.addPendingOffer(servicer, address(offerLocker), activeOffer, 200);
        _addPendingBidEmptyCollateral(address(bidLocker), staleBid, 100);
        _addPendingBidEmptyCollateral(address(bidLocker), activeBid, 200);

        bytes32[] memory offerTargets = new bytes32[](1);
        offerTargets[0] = staleOffer;
        bytes32[] memory bidTargets = new bytes32[](1);
        bidTargets[0] = staleBid;

        vm.expectEmit(true, true, true, true);
        emit TermFinanceCleanupFuse.TermFinanceCleanupExecuted(address(harness), servicer, 1, 1);
        harness.enter(_enterData(offerTargets, bidTargets));

        assertFalse(harness.isOfferPending(servicer, staleOffer), "stale offer pruned");
        assertTrue(harness.isOfferPending(servicer, activeOffer), "active offer kept");
        assertFalse(harness.isBidPending(servicer, staleBid), "stale bid pruned");
        assertTrue(harness.isBidPending(servicer, activeBid), "active bid kept");
    }

    // ---------- snapshot iteration safety ----------

    /// @notice The `_pruneStoredBids` loop reads the snapshot ONCE up front and then
    ///         mutates storage via swap-and-pop. Iterating against the snapshot ids
    ///         (rather than the storage array) ensures we don't skip entries even when
    ///         every single entry is cleared in the same call.
    function testCleanupHandlesStorageMutationCorrectly() public {
        uint256 n = 5;
        bytes32[] memory ids = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = bytes32(uint256(0xB0 + i));
            _seedClearedBid(ids[i]);
            _addPendingBidEmptyCollateral(address(bidLocker), ids[i], 100 + i);
        }
        assertEq(harness.pendingBidsLength(servicer), n, "seeded");

        vm.expectEmit(true, true, true, true);
        emit TermFinanceCleanupFuse.TermFinanceCleanupExecuted(address(harness), servicer, 0, n);
        harness.enter(_enterData(_emptyIds(), _emptyIds()));

        for (uint256 i; i < n; ++i) {
            assertFalse(harness.isBidPending(servicer, ids[i]), "id pruned");
        }
        assertEq(harness.pendingBidsLength(servicer), 0, "all entries pruned");
    }

    /// @notice Mixed snapshot: stale bids INTERLEAVED with live bids in storage. Iterating
    ///         against the snapshot ids guarantees every stale entry is visited even after
    ///         swap-and-pop rearranges the storage array.
    function testCleanupSnapshotIterationVisitsAllEntriesAcrossSwapAndPop() public {
        // Layout: stale, live, stale, live, stale → 3 prunes, 2 keeps.
        bytes32[] memory ids = new bytes32[](5);
        bool[] memory shouldStay = new bool[](5);

        address liveBidder = makeAddr("liveBidder");
        for (uint256 i; i < 5; ++i) {
            ids[i] = bytes32(uint256(0xB0 + i));
            if (i % 2 == 0) {
                _seedClearedBid(ids[i]); // stale
            } else {
                _seedActiveBid(ids[i], liveBidder, 1_000_000); // live
                shouldStay[i] = true;
            }
            _addPendingBidEmptyCollateral(address(bidLocker), ids[i], 100 + i);
        }

        vm.expectEmit(true, true, true, true);
        emit TermFinanceCleanupFuse.TermFinanceCleanupExecuted(address(harness), servicer, 0, 3);
        harness.enter(_enterData(_emptyIds(), _emptyIds()));

        for (uint256 i; i < 5; ++i) {
            assertEq(harness.isBidPending(servicer, ids[i]), shouldStay[i], "snapshot iteration preserved");
        }
        assertEq(harness.pendingBidsLength(servicer), 2, "two live bids retained");
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Errors} from "contracts/libraries/errors/Errors.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {
    TermFinanceOfferFuse,
    TermFinanceOfferFuseEnterData,
    TermFinanceOfferFuseExitData
} from "contracts/fuses/term_finance/TermFinanceOfferFuse.sol";
import {
    TermFinancePendingOffersStorageLib
} from "contracts/fuses/term_finance/lib/TermFinancePendingOffersStorageLib.sol";

import {TermFinanceOfferFuseHarness} from "./mocks/TermFinanceOfferFuseHarness.sol";
import {MockERC20Decimals} from "./mocks/MockERC20Decimals.sol";
import {MockTermAuctionOfferLocker} from "./mocks/MockTermAuctionOfferLocker.sol";
import {MockTermController} from "./mocks/MockTermController.sol";
import {MockTermRepoServicer} from "./mocks/MockTermRepoServicer.sol";

contract TermFinanceOfferFuseTest is Test {
    /// @dev Local copies of fuse events for `vm.expectEmit` assertions.
    event TermFinanceOfferLocked(
        address version, address servicer, address offerLocker, bytes32 offerId, uint256 amount, bytes32 offerPriceHash
    );
    event TermFinanceOfferUnlocked(address version, address servicer, address offerLocker, bytes32[] offerIds);

    uint256 internal constant MARKET_ID = 52;

    /// @dev Canonical WithdrawManager ERC-7201 slot — mirrors `PlasmaVaultStorageLib`'s
    ///      `WITHDRAW_MANAGER` constant (private there). Used by tests to toggle the
    ///      `_assertWithdrawManagerSet()` guard via `vm.store` on the harness address.
    bytes32 internal constant WITHDRAW_MANAGER_SLOT =
        0x465d2ff0062318fe6f4c7e9ac78cfcd70bc86a1d992722875ef83a9770513100;

    /// @dev Sentinel WithdrawManager address — any non-zero value satisfies the guard.
    address internal constant WITHDRAW_MANAGER = address(0xCAFE);

    TermFinanceOfferFuseHarness harness;
    MockTermController controller;
    MockTermRepoServicer servicer;
    MockTermAuctionOfferLocker offerLocker;
    MockERC20Decimals usdc;
    address termRepoLocker;

    function setUp() public {
        controller = new MockTermController();
        harness = new TermFinanceOfferFuseHarness(MARKET_ID, address(controller));

        usdc = new MockERC20Decimals("USDC", "USDC", 6);
        servicer = new MockTermRepoServicer();
        offerLocker = new MockTermAuctionOfferLocker();
        termRepoLocker = makeAddr("termRepoLocker");

        servicer.setTermRepoLocker(termRepoLocker);
        servicer.setPurchaseToken(address(usdc));
        offerLocker.setTermRepoServicer(address(servicer));
        offerLocker.setTermRepoLocker(termRepoLocker);

        controller.setIsTermDeployed(address(servicer), true);
        controller.setIsTermDeployed(address(offerLocker), true); // locker must be Term-deployed

        bytes32[] memory subs = new bytes32[](1);
        subs[0] = PlasmaVaultConfigLib.addressToBytes32(address(servicer));
        harness.setMarketSubstrates(MARKET_ID, subs);

        // Fund vault.
        usdc.mint(address(harness), 10_000_000);

        // Default: WithdrawManager is configured (invariant satisfied).
        _setWithdrawManager(WITHDRAW_MANAGER);
    }

    function _setWithdrawManager(address manager_) internal {
        vm.store(address(harness), WITHDRAW_MANAGER_SLOT, bytes32(uint256(uint160(manager_))));
    }

    function _clearWithdrawManagerSlot() internal {
        _setWithdrawManager(address(0));
    }

    function _enterData(uint256 amt_, bytes32 hash_, bytes32 existingId_)
        internal
        view
        returns (TermFinanceOfferFuseEnterData memory)
    {
        return TermFinanceOfferFuseEnterData({
            servicer: address(servicer),
            offerLocker: address(offerLocker),
            amount: amt_,
            offerPriceHash: hash_,
            existingOfferId: existingId_
        });
    }

    // ============ constructor ============

    function test_constructor_setsImmutables() public view {
        assertEq(harness.MARKET_ID(), MARKET_ID);
        assertEq(harness.TERM_CONTROLLER(), address(controller));
        assertEq(harness.VERSION(), address(harness));
    }

    function test_constructor_revertsOnZeroMarketId() public {
        vm.expectRevert(Errors.WrongValue.selector);
        new TermFinanceOfferFuseHarness(0, address(controller));
    }

    function test_constructor_revertsOnZeroController() public {
        vm.expectRevert(Errors.WrongAddress.selector);
        new TermFinanceOfferFuseHarness(MARKET_ID, address(0));
    }

    // ============ enter — happy path ============

    function test_enter_happyPath_locksOfferAndWritesPending() public {
        uint256 amt = 1_000_000;
        bytes32 hash_ = keccak256("hash-1");

        // Mock OfferLocker assigns id starting at 0x1.
        bytes32 expectedId = bytes32(uint256(0x1));

        // Assert full event payload.
        vm.expectEmit(true, true, true, true);
        emit TermFinanceOfferLocked(address(harness), address(servicer), address(offerLocker), expectedId, amt, hash_);
        harness.enter(_enterData(amt, hash_, bytes32(0)));

        assertTrue(harness.isOfferPending(address(servicer), expectedId), "pending entry written");

        (address[] memory lockers, bytes32[] memory ids, uint256[] memory amounts) =
            harness.getPendingOffersForServicer(address(servicer));
        assertEq(lockers.length, 1);
        assertEq(lockers[0], address(offerLocker));
        assertEq(ids.length, 1);
        assertEq(ids[0], expectedId);
        assertEq(amounts[0], amt);
    }

    function test_enter_happyPath_resetsApprovalToZero() public {
        harness.enter(_enterData(1_000_000, keccak256("h"), bytes32(0)));
        assertEq(usdc.allowance(address(harness), termRepoLocker), 0, "allowance reset after lockOffers");
    }

    function test_enter_happyPath_approvesTermRepoLockerNotOfferLocker() public {
        // We can't observe mid-call allowance directly without instrumentation; check the
        // negative: allowance to offerLocker stays zero throughout.
        harness.enter(_enterData(1_000_000, keccak256("h"), bytes32(0)));
        assertEq(usdc.allowance(address(harness), address(offerLocker)), 0, "must not approve offerLocker");
        assertEq(usdc.allowance(address(harness), termRepoLocker), 0, "termRepoLocker allowance reset to 0");
    }

    function test_enter_editFlow_removesOldPendingBeforeAddingNew() public {
        // First lock — get id 0x1.
        harness.enter(_enterData(1_000_000, keccak256("h"), bytes32(0)));
        bytes32 firstId = bytes32(uint256(0x1));
        assertTrue(harness.isOfferPending(address(servicer), firstId));

        // Edit: provide firstId as existing, mock will allocate next id (0x2).
        // (Note: real Term Finance keeps id stable on edit; our mock allocates fresh
        // when submission.id != 0 it reuses; check the mock.)
        // Mock checks: if `s.id == 0` mints new id; else reuses s.id. So edit reuses firstId.
        harness.enter(_enterData(2_000_000, keccak256("h2"), firstId));

        // After edit: storage should have ONE entry (firstId) with amount = 2_000_000.
        (, bytes32[] memory ids, uint256[] memory amounts) = harness.getPendingOffersForServicer(address(servicer));
        assertEq(ids.length, 1);
        assertEq(ids[0], firstId);
        assertEq(amounts[0], 2_000_000);
    }

    // ============ enter — guards ============

    function test_enter_revertsOnSubstrateNotGranted() public {
        // Wipe substrates.
        bytes32[] memory empty = new bytes32[](0);
        harness.setMarketSubstrates(MARKET_ID, empty);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceOfferFuse.TermFinanceOfferFuseUnsupportedMarket.selector, address(servicer)
            )
        );
        harness.enter(_enterData(1_000_000, keccak256("h"), bytes32(0)));
    }

    function test_enter_revertsOnControllerNotDeployed() public {
        controller.setIsTermDeployed(address(servicer), false);
        vm.expectRevert(
            abi.encodeWithSelector(TermFinanceOfferFuse.TermFinanceOfferFuseTermNotDeployed.selector, address(servicer))
        );
        harness.enter(_enterData(1_000_000, keccak256("h"), bytes32(0)));
    }

    /// @notice A spoofed offerLocker that returns the real granted servicer (so it
    ///         would pass the `termRepoServicer()` pairing) but is NOT registered with the Term
    ///         controller is rejected — preventing the phantom-pending-offer NAV inflation.
    function test_enter_revertsOnSpoofedLockerNotDeployed() public {
        MockTermAuctionOfferLocker spoof = new MockTermAuctionOfferLocker();
        spoof.setTermRepoServicer(address(servicer)); // would pass the pairing check
        spoof.setTermRepoLocker(termRepoLocker);
        // NOT flagged via controller.setIsTermDeployed(spoof, true).

        TermFinanceOfferFuseEnterData memory data = TermFinanceOfferFuseEnterData({
            servicer: address(servicer),
            offerLocker: address(spoof),
            amount: 1_000_000,
            offerPriceHash: keccak256("h"),
            existingOfferId: bytes32(0)
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceOfferFuse.TermFinanceOfferFuseOfferLockerNotDeployed.selector, address(spoof)
            )
        );
        harness.enter(data);
    }

    function test_enter_revertsOnOfferLockerMismatch() public {
        // Wire offerLocker to a DIFFERENT servicer.
        MockTermRepoServicer other = new MockTermRepoServicer();
        offerLocker.setTermRepoServicer(address(other));

        // Assert full (expected, actual) payload, not just selector.
        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceOfferFuse.TermFinanceOfferFuseOfferLockerMismatch.selector, address(other), address(servicer)
            )
        );
        harness.enter(_enterData(1_000_000, keccak256("h"), bytes32(0)));
    }

    function test_enter_revertsOnZeroAmount() public {
        vm.expectRevert(TermFinanceOfferFuse.TermFinanceOfferFuseZeroAmount.selector);
        harness.enter(_enterData(0, keccak256("h"), bytes32(0)));
    }

    function test_enter_propagatesLockerRevert() public {
        offerLocker.setLockOffersReverts(true);
        vm.expectRevert(bytes("MockOfferLocker: lockOffers reverts"));
        harness.enter(_enterData(1_000_000, keccak256("h"), bytes32(0)));
    }

    // ============ exit ============

    function test_exit_unlocksAndRemovesPendingEntries() public {
        // Lock two offers.
        harness.enter(_enterData(1_000_000, keccak256("h1"), bytes32(0)));
        harness.enter(_enterData(2_000_000, keccak256("h2"), bytes32(0)));

        bytes32 id1 = bytes32(uint256(0x1));
        bytes32 id2 = bytes32(uint256(0x2));
        assertTrue(harness.isOfferPending(address(servicer), id1));
        assertTrue(harness.isOfferPending(address(servicer), id2));

        // Exit both.
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;

        // Assert full event payload.
        vm.expectEmit(true, true, true, true);
        emit TermFinanceOfferUnlocked(address(harness), address(servicer), address(offerLocker), ids);
        harness.exit(
            TermFinanceOfferFuseExitData({
                servicer: address(servicer), offerLocker: address(offerLocker), offerIds: ids
            })
        );

        assertFalse(harness.isOfferPending(address(servicer), id1));
        assertFalse(harness.isOfferPending(address(servicer), id2));
    }

    function test_exit_unknownIds_isNoOpForStorage() public {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(0xDEAD));
        // Should not revert (locker.unlockOffers no-ops on unknown; storage remove is idempotent).
        harness.exit(
            TermFinanceOfferFuseExitData({
                servicer: address(servicer), offerLocker: address(offerLocker), offerIds: ids
            })
        );
    }

    function test_exit_revertsOnSubstrateNotGranted() public {
        bytes32[] memory empty = new bytes32[](0);
        harness.setMarketSubstrates(MARKET_ID, empty);

        bytes32[] memory ids = new bytes32[](0);
        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceOfferFuse.TermFinanceOfferFuseUnsupportedMarket.selector, address(servicer)
            )
        );
        harness.exit(
            TermFinanceOfferFuseExitData({
                servicer: address(servicer), offerLocker: address(offerLocker), offerIds: ids
            })
        );
    }

    function test_exit_revertsOnOfferLockerMismatch() public {
        MockTermRepoServicer other = new MockTermRepoServicer();
        offerLocker.setTermRepoServicer(address(other));

        bytes32[] memory ids = new bytes32[](0);
        // Assert full (expected, actual) payload, not just selector.
        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceOfferFuse.TermFinanceOfferFuseOfferLockerMismatch.selector, address(other), address(servicer)
            )
        );
        harness.exit(
            TermFinanceOfferFuseExitData({
                servicer: address(servicer), offerLocker: address(offerLocker), offerIds: ids
            })
        );
    }

    // ============ lockOffers return-length guard ============

    /// @notice A malicious/buggy locker returning an empty array must
    ///         revert with a specific selector (not an OOB array access from `ids[0]`).
    function test_enter_revertsOnLockOffersReturningEmpty() public {
        offerLocker.setLockOffersReturnsEmpty(true);

        vm.expectRevert(
            abi.encodeWithSelector(TermFinanceOfferFuse.TermFinanceOfferFuseUnexpectedLockResult.selector, uint256(0))
        );
        harness.enter(_enterData(1_000_000, keccak256("h"), bytes32(0)));
    }

    /// @notice A malicious locker padding the return array (≥2 ids) must
    ///         also revert to prevent orphaned ids that hold vault funds but aren't tracked.
    function test_enter_revertsOnLockOffersReturningExtraIds() public {
        offerLocker.setLockOffersReturnsExtra(true);

        vm.expectRevert(
            abi.encodeWithSelector(TermFinanceOfferFuse.TermFinanceOfferFuseUnexpectedLockResult.selector, uint256(2))
        );
        harness.enter(_enterData(1_000_000, keccak256("h"), bytes32(0)));
    }

    // ============ WithdrawManager runtime check ============

    function test_enter_revertsWhenWithdrawManagerNotSet() public {
        _clearWithdrawManagerSlot();

        vm.expectRevert(TermFinanceOfferFuse.TermFinanceOfferFuseWithdrawManagerRequired.selector);
        harness.enter(_enterData(1_000_000, keccak256("h"), bytes32(0)));
    }

    function test_exit_revertsWhenWithdrawManagerNotSet() public {
        _clearWithdrawManagerSlot();

        bytes32[] memory ids = new bytes32[](0);
        vm.expectRevert(TermFinanceOfferFuse.TermFinanceOfferFuseWithdrawManagerRequired.selector);
        harness.exit(
            TermFinanceOfferFuseExitData({
                servicer: address(servicer), offerLocker: address(offerLocker), offerIds: ids
            })
        );
    }

    /// @notice Ordering: WithdrawManager check runs FIRST, before `_assertServicerAllowed`.
    ///         With WithdrawManager zeroed AND substrates wiped (which would otherwise revert
    ///         with `UnsupportedMarket`), the revert must be the WithdrawManager selector.
    function testEnterShouldCheckWithdrawManagerBeforeOtherValidation() public {
        bytes32[] memory empty = new bytes32[](0);
        harness.setMarketSubstrates(MARKET_ID, empty);
        _clearWithdrawManagerSlot();

        vm.expectRevert(TermFinanceOfferFuse.TermFinanceOfferFuseWithdrawManagerRequired.selector);
        harness.enter(_enterData(1_000_000, keccak256("h"), bytes32(0)));
    }

    /// @notice Ordering: WithdrawManager check runs FIRST in `exit`, before `_assertServicerAllowed`.
    function testExitShouldCheckWithdrawManagerBeforeOtherValidation() public {
        bytes32[] memory empty = new bytes32[](0);
        harness.setMarketSubstrates(MARKET_ID, empty);
        _clearWithdrawManagerSlot();

        bytes32[] memory ids = new bytes32[](0);
        vm.expectRevert(TermFinanceOfferFuse.TermFinanceOfferFuseWithdrawManagerRequired.selector);
        harness.exit(
            TermFinanceOfferFuseExitData({
                servicer: address(servicer), offerLocker: address(offerLocker), offerIds: ids
            })
        );
    }

    // ============ pending-offers cap ============

    /// @notice enter must revert with `TooManyPendingOffers` when a fresh insert
    ///         would push the post-insert length over `MAX_PENDING_OFFERS_PER_SERVICER`.
    function test_enter_revertsWhenPendingOffersExceedCap() public {
        uint256 cap = TermFinancePendingOffersStorageLib.MAX_PENDING_OFFERS_PER_SERVICER;
        assertEq(cap, 500, "offers cap is 500 (deliberately higher than the bid side's 150)");

        for (uint256 i; i < cap; ++i) {
            harness.enter(_enterData(1_000_000, keccak256(abi.encode("seed", i)), bytes32(0)));
        }
        assertEq(harness.pendingOffersLength(address(servicer)), cap, "exactly cap offers tracked");

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceOfferFuse.TermFinanceOfferFuseTooManyPendingOffers.selector, address(servicer), cap + 1
            )
        );
        harness.enter(_enterData(1_000_000, keccak256("overflow"), bytes32(0)));

        assertEq(harness.pendingOffersLength(address(servicer)), cap, "length unchanged after revert");
    }

    /// @notice A cap-breach enter must short-circuit BEFORE the external
    ///         `lockOffers` call (no approval side effects, no locker invocation). Uses the
    ///         `count = 0` form of `vm.expectCall`, which intercepts at the EVM boundary and is
    ///         immune to the atomic state-revert.
    function test_enter_capBreachDoesNotInvokeLockOffers() public {
        uint256 cap = TermFinancePendingOffersStorageLib.MAX_PENDING_OFFERS_PER_SERVICER;

        for (uint256 i; i < cap; ++i) {
            harness.enter(_enterData(1_000_000, keccak256(abi.encode("seed", i)), bytes32(0)));
        }
        assertEq(harness.pendingOffersLength(address(servicer)), cap, "cap reached");

        vm.expectCall(address(offerLocker), abi.encodeWithSelector(MockTermAuctionOfferLocker.lockOffers.selector), 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceOfferFuse.TermFinanceOfferFuseTooManyPendingOffers.selector, address(servicer), cap + 1
            )
        );
        harness.enter(_enterData(1_000_000, keccak256("overflow"), bytes32(0)));

        assertEq(harness.pendingOffersLength(address(servicer)), cap, "length unchanged after revert");
    }

    /// @notice The edit-flow path is EXEMPT from the cap when the id is actually
    ///         tracked — re-inserting an existing id is an in-place refresh (length unchanged).
    function test_enter_doesNotEnforceCapOnEditFlow() public {
        uint256 cap = TermFinancePendingOffersStorageLib.MAX_PENDING_OFFERS_PER_SERVICER;

        for (uint256 i; i < cap; ++i) {
            harness.enter(_enterData(1_000_000, keccak256(abi.encode("seed", i)), bytes32(0)));
        }
        assertEq(harness.pendingOffersLength(address(servicer)), cap, "cap reached");

        // Edit-flow at the cap: existingOfferId = 0x1 (first allocated). Must succeed and not
        // increase the length (in-place refresh), and must refresh the amount.
        bytes32 existing = bytes32(uint256(0x1));
        assertTrue(harness.isOfferPending(address(servicer), existing), "first id present");

        harness.enter(_enterData(5_000_000, keccak256("edit"), existing));
        assertEq(harness.pendingOffersLength(address(servicer)), cap, "length unchanged on edit at cap");

        (, bytes32[] memory ids, uint256[] memory amounts) = harness.getPendingOffersForServicer(address(servicer));
        bool found;
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] == existing) {
                assertEq(amounts[i], 5_000_000, "refreshed amount on edit");
                found = true;
                break;
            }
        }
        assertTrue(found, "edited offer retained");
    }

    /// @notice Regression: at the cap, a non-zero `existingOfferId` that is NOT
    ///         tracked MUST trigger the cap-check (storage would grow because
    ///         `removePendingOfferIfExists` returns `false`). Without the `bool removed` signal
    ///         this path quietly appended a new entry past the cap.
    function test_enter_editFlowWithFakeExistingOfferIdRespectsCap() public {
        uint256 cap = TermFinancePendingOffersStorageLib.MAX_PENDING_OFFERS_PER_SERVICER;

        for (uint256 i; i < cap; ++i) {
            harness.enter(_enterData(1_000_000, keccak256(abi.encode("seed", i)), bytes32(0)));
        }
        assertEq(harness.pendingOffersLength(address(servicer)), cap, "cap reached");

        bytes32 fake = keccak256("FAKE-EXISTING-ID");
        assertFalse(harness.isOfferPending(address(servicer), fake), "fake id NOT tracked pre-call");

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceOfferFuse.TermFinanceOfferFuseTooManyPendingOffers.selector, address(servicer), cap + 1
            )
        );
        harness.enter(_enterData(1_000_000, keccak256("attack"), fake));

        assertEq(harness.pendingOffersLength(address(servicer)), cap, "length unchanged after attack");
    }

    /// @notice Paired with the fake-id regression: edit-flow with a KNOWN id must
    ///         still be exempt — the `removed=true` branch keeps the length unchanged. Ensures
    ///         the fix did not regress the legitimate edit-at-cap path.
    function test_enter_editFlowWithKnownExistingOfferIdRespectsCapExemption() public {
        uint256 cap = TermFinancePendingOffersStorageLib.MAX_PENDING_OFFERS_PER_SERVICER;

        for (uint256 i; i < cap; ++i) {
            harness.enter(_enterData(1_000_000, keccak256(abi.encode("seed", i)), bytes32(0)));
        }
        assertEq(harness.pendingOffersLength(address(servicer)), cap, "cap reached");

        bytes32 existing = bytes32(uint256(0x1));
        assertTrue(harness.isOfferPending(address(servicer), existing), "known id present");

        harness.enter(_enterData(1_000_000, keccak256("edit-ok"), existing));
        assertEq(harness.pendingOffersLength(address(servicer)), cap, "edit-flow exempt at cap");
    }
}

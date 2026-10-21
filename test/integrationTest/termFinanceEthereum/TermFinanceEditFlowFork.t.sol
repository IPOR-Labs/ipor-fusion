// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {IExtTermAuctionBidLocker} from "contracts/fuses/term_finance/ext/IExtTermAuctionBidLocker.sol";
import {IExtTermRepoServicer} from "contracts/fuses/term_finance/ext/IExtTermRepoServicer.sol";
import {IExtTermAuctionOfferLocker} from "contracts/fuses/term_finance/ext/IExtTermAuctionOfferLocker.sol";
import {TermFinanceBidFuse, TermFinanceBidFuseEnterData} from "contracts/fuses/term_finance/TermFinanceBidFuse.sol";
import {
    TermFinanceOfferFuse,
    TermFinanceOfferFuseEnterData
} from "contracts/fuses/term_finance/TermFinanceOfferFuse.sol";
import {TermFinanceSubstrateLib} from "contracts/fuses/term_finance/lib/TermFinanceSubstrateLib.sol";

import {TermFinanceBidFuseHarness} from "../../unitTest/fuses/term_finance/mocks/TermFinanceBidFuseHarness.sol";
import {TermFinanceOfferFuseHarness} from "../../unitTest/fuses/term_finance/mocks/TermFinanceOfferFuseHarness.sol";

/// @title TermFinanceEditFlowFork
/// @notice IL-8741 regression against live Ethereum: a bid locked on one auction locker of a servicer must not be
///         "edited" through the sibling locker of the same servicer. On the live lockers Term edits in place only
///         when the id exists in THAT locker, otherwise it mints a new id and leaves the original bid (and its
///         collateral in the TermRepoLocker) live — the fuse would drop the original from tracking.
/// @dev Own fork block (24888300): both lockers of servicer `0x1195...8657` are inside their submission window.
contract TermFinanceEditFlowFork is Test {
    uint256 private constant FORK_BLOCK = 24888300;
    uint256 private constant MARKET_ID = 52;

    address private constant TERM_CONTROLLER = 0x21FC7B250CCAeECDb2abb38e04617D1f24D98772;
    address private constant SERVICER = 0x11951C559cBA31E83f8032cFF4bd854eA0228657;
    address private constant COLLATERAL_MANAGER = 0x9b00ee0b1cE01f74B1d18fAc682D4c9A3077C7d3;
    address private constant PT_REUSD = 0x3EAA0F0f0A5d3D595ae4e4b0D27f439d01c3E7b2;
    address private constant LOCKER_1 = 0x17a0F435535a7187003d3a03C931691cFF9e9ddF;
    address private constant LOCKER_2 = 0x4d28F2722b6288Fd0D6F4320fE2Ab4d347448673;
    address private constant OFFER_LOCKER_1 = 0x00316d15d15631Ca68750356aa9e0773911837C3;
    address private constant OFFER_LOCKER_2 = 0x8f6e393e85bccB5f80CaeEc72B750E664Fd50eb2;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @dev WithdrawManager ERC-7201 storage slot used by `PlasmaVaultStorageLib`.
    bytes32 private constant WITHDRAW_MANAGER_SLOT = 0x465d2ff0062318fe6f4c7e9ac78cfcd70bc86a1d992722875ef83a9770513100;

    uint256 private constant BID_AMOUNT = 1_000e6;
    uint256 private constant COLLATERAL_AMOUNT = 2_000e6;

    uint256 private constant OFFER_AMOUNT = 1_000e6;

    TermFinanceBidFuseHarness private harness;
    TermFinanceOfferFuseHarness private offerHarness;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);

        // Both auctions of the servicer are open at the pinned block.
        assertEq(IExtTermAuctionBidLocker(LOCKER_1).termRepoServicer(), SERVICER, "L1 paired");
        assertEq(IExtTermAuctionBidLocker(LOCKER_2).termRepoServicer(), SERVICER, "L2 paired");
        assertLt(block.timestamp, IExtTermAuctionBidLocker(LOCKER_1).revealTime(), "L1 before reveal");
        assertLt(block.timestamp, IExtTermAuctionBidLocker(LOCKER_2).revealTime(), "L2 before reveal");
        assertGe(block.timestamp, IExtTermAuctionBidLocker(LOCKER_1).auctionStartTime(), "L1 started");
        assertGe(block.timestamp, IExtTermAuctionBidLocker(LOCKER_2).auctionStartTime(), "L2 started");

        harness = new TermFinanceBidFuseHarness(MARKET_ID, TERM_CONTROLLER);
        bytes32[] memory subs = new bytes32[](2);
        subs[0] = PlasmaVaultConfigLib.addressToBytes32(SERVICER);
        subs[1] = TermFinanceSubstrateLib.collateralPairKey(SERVICER, PT_REUSD);
        harness.setMarketSubstrates(MARKET_ID, subs);
        vm.store(address(harness), WITHDRAW_MANAGER_SLOT, bytes32(uint256(uint160(address(0xBEEF)))));

        deal(PT_REUSD, address(harness), 10 * COLLATERAL_AMOUNT);

        // Both offer lockers of the servicer are open as well.
        assertEq(IExtTermAuctionOfferLocker(OFFER_LOCKER_1).termRepoServicer(), SERVICER, "O1 paired");
        assertEq(IExtTermAuctionOfferLocker(OFFER_LOCKER_2).termRepoServicer(), SERVICER, "O2 paired");
        assertLt(block.timestamp, IExtTermAuctionOfferLocker(OFFER_LOCKER_1).revealTime(), "O1 before reveal");
        assertLt(block.timestamp, IExtTermAuctionOfferLocker(OFFER_LOCKER_2).revealTime(), "O2 before reveal");

        offerHarness = new TermFinanceOfferFuseHarness(MARKET_ID, TERM_CONTROLLER);
        bytes32[] memory offerSubs = new bytes32[](2);
        offerSubs[0] = PlasmaVaultConfigLib.addressToBytes32(SERVICER);
        offerSubs[1] = TermFinanceSubstrateLib.repoTokenHoldingKey(SERVICER);
        offerHarness.setMarketSubstrates(MARKET_ID, offerSubs);
        vm.store(address(offerHarness), WITHDRAW_MANAGER_SLOT, bytes32(uint256(uint160(address(0xBEEF)))));
        deal(USDC, address(offerHarness), 10 * OFFER_AMOUNT);
    }

    function _offerEnterData(
        address locker_,
        bytes32 existingId_
    ) private pure returns (TermFinanceOfferFuseEnterData memory d) {
        d.servicer = SERVICER;
        d.offerLocker = locker_;
        d.amount = OFFER_AMOUNT;
        d.offerPriceHash = keccak256(abi.encode(uint256(1e18), uint256(1)));
        d.existingOfferId = existingId_;
    }

    function _enterData(
        address locker_,
        bytes32 existingId_
    ) private view returns (TermFinanceBidFuseEnterData memory d) {
        d.servicer = SERVICER;
        d.bidLocker = locker_;
        d.collateralManager = COLLATERAL_MANAGER;
        d.amount = BID_AMOUNT;
        d.bidPriceHash = keccak256(abi.encode(uint256(1e18), uint256(1)));
        d.existingBidId = existingId_;
        d.collateralTokens = new address[](1);
        d.collateralTokens[0] = PT_REUSD;
        d.collateralAmounts = new uint256[](1);
        d.collateralAmounts[0] = COLLATERAL_AMOUNT;
    }

    function testForkEditThroughSiblingLockerReverts() public {
        // Real lockBids on L1.
        harness.enter(_enterData(LOCKER_1, bytes32(0)));

        (address[] memory lockers, bytes32[] memory ids, , , ) = harness.getPendingBidsForServicer(SERVICER);
        assertEq(ids.length, 1, "one tracked bid");
        assertEq(lockers[0], LOCKER_1, "tracked against L1");
        bytes32 x = ids[0];

        address termRepoLocker = IExtTermRepoServicer(SERVICER).termRepoLocker();
        uint256 escrowedBefore = IERC20(PT_REUSD).balanceOf(termRepoLocker);
        uint256 vaultBefore = IERC20(PT_REUSD).balanceOf(address(harness));

        // "Edit" X through L2: L2 does not know X, so Term would mint a new id and leave X live in L1.
        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBidFuse.TermFinanceBidFuseExistingBidLockerMismatch.selector,
                x,
                LOCKER_1,
                LOCKER_2
            )
        );
        harness.enter(_enterData(LOCKER_2, x));

        // Nothing moved and X is still tracked against L1.
        assertTrue(harness.isBidPending(SERVICER, x), "X still tracked");
        assertEq(harness.pendingBidsLength(SERVICER), 1, "tracked set unchanged");
        assertEq(IERC20(PT_REUSD).balanceOf(termRepoLocker), escrowedBefore, "escrow unchanged");
        assertEq(IERC20(PT_REUSD).balanceOf(address(harness)), vaultBefore, "vault balance unchanged");
    }

    function testForkEditOnSameLockerKeepsIdAndTracking() public {
        harness.enter(_enterData(LOCKER_1, bytes32(0)));
        (, bytes32[] memory ids, , , ) = harness.getPendingBidsForServicer(SERVICER);
        bytes32 x = ids[0];

        harness.enter(_enterData(LOCKER_1, x));

        (address[] memory lockers, bytes32[] memory idsAfter, , , ) = harness.getPendingBidsForServicer(SERVICER);
        assertEq(idsAfter.length, 1, "length unchanged");
        assertEq(idsAfter[0], x, "same id returned by the live locker");
        assertEq(lockers[0], LOCKER_1, "still bound to L1");
    }

    function testForkOfferEditThroughSiblingLockerReverts() public {
        offerHarness.enter(_offerEnterData(OFFER_LOCKER_1, bytes32(0)));

        (address[] memory lockers, bytes32[] memory ids, ) = offerHarness.getPendingOffersForServicer(SERVICER);
        assertEq(ids.length, 1, "one tracked offer");
        assertEq(lockers[0], OFFER_LOCKER_1, "tracked against O1");
        bytes32 x = ids[0];

        address termRepoLocker = IExtTermRepoServicer(SERVICER).termRepoLocker();
        uint256 escrowedBefore = IERC20(USDC).balanceOf(termRepoLocker);
        uint256 vaultBefore = IERC20(USDC).balanceOf(address(offerHarness));

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceOfferFuse.TermFinanceOfferFuseExistingOfferLockerMismatch.selector,
                x,
                OFFER_LOCKER_1,
                OFFER_LOCKER_2
            )
        );
        offerHarness.enter(_offerEnterData(OFFER_LOCKER_2, x));

        assertTrue(offerHarness.isOfferPending(SERVICER, x), "X still tracked");
        assertEq(offerHarness.pendingOffersLength(SERVICER), 1, "tracked set unchanged");
        assertEq(IERC20(USDC).balanceOf(termRepoLocker), escrowedBefore, "escrow unchanged");
        assertEq(IERC20(USDC).balanceOf(address(offerHarness)), vaultBefore, "vault balance unchanged");
    }

    function testForkOfferEditOnSameLockerKeepsIdAndTracking() public {
        offerHarness.enter(_offerEnterData(OFFER_LOCKER_1, bytes32(0)));
        (, bytes32[] memory ids, ) = offerHarness.getPendingOffersForServicer(SERVICER);
        bytes32 x = ids[0];

        offerHarness.enter(_offerEnterData(OFFER_LOCKER_1, x));

        (address[] memory lockers, bytes32[] memory idsAfter, ) = offerHarness.getPendingOffersForServicer(SERVICER);
        assertEq(idsAfter.length, 1, "length unchanged");
        assertEq(idsAfter[0], x, "same id returned by the live locker");
        assertEq(lockers[0], OFFER_LOCKER_1, "still bound to O1");
    }
}

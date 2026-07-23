// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Errors} from "contracts/libraries/errors/Errors.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {
    TermFinanceBidFuse,
    TermFinanceBidFuseEnterData,
    TermFinanceBidFuseExitData
} from "contracts/fuses/term_finance/TermFinanceBidFuse.sol";
import {TermFinancePendingBidsStorageLib} from "contracts/fuses/term_finance/lib/TermFinancePendingBidsStorageLib.sol";
import {TermFinanceSubstrateLib} from "contracts/fuses/term_finance/lib/TermFinanceSubstrateLib.sol";

import {TermFinanceBidFuseHarness} from "./mocks/TermFinanceBidFuseHarness.sol";
import {MockERC20Decimals} from "./mocks/MockERC20Decimals.sol";
import {MockTermAuctionBidLocker} from "./mocks/MockTermAuctionBidLocker.sol";
import {MockTermController} from "./mocks/MockTermController.sol";
import {MockTermRepoServicer} from "./mocks/MockTermRepoServicer.sol";

/// @notice Unit-test suite for `TermFinanceBidFuse`.
/// @dev Mirror of `TermFinanceOfferFuseTest` with additions specific to the borrower side:
///      - WithdrawManager runtime check
///      - CollateralManager pairing impersonation guard
///      - Per-token collateral substrate allowlist (TYPE 0x01)
///      - Submission-window cutoff at `revealTime`
///      - Edit-flow exempt from pending-bids cap
///      - `MAX_PENDING_BIDS_PER_SERVICER = 150` cap
///      - `lockBids` return-length guard (UnexpectedLockResult)
///      - Multi-collateral approvals + cleanup
contract TermFinanceBidFuseTest is Test {
    /// @dev Local copies of fuse events for `vm.expectEmit` assertions.
    event TermFinanceBidLocked(
        address version,
        address servicer,
        address bidLocker,
        bytes32 bidId,
        uint256 amount,
        bytes32 bidPriceHash,
        address[] collateralTokens,
        uint256[] collateralAmounts
    );
    event TermFinanceBidUnlocked(address version, address servicer, address bidLocker, bytes32[] bidIds);

    uint256 internal constant MARKET_ID = 52;

    /// @dev Canonical WithdrawManager ERC-7201 slot — mirrors `PlasmaVaultStorageLib`'s
    ///      `WITHDRAW_MANAGER` constant (private there). Used by tests to toggle the
    ///      `_assertWithdrawManagerSet()` guard via `vm.store` on the harness address.
    bytes32 internal constant WITHDRAW_MANAGER_SLOT =
        0x465d2ff0062318fe6f4c7e9ac78cfcd70bc86a1d992722875ef83a9770513100;

    /// @dev Sentinel WithdrawManager address — any non-zero value is sufficient for the
    ///      `_assertWithdrawManagerSet()` guard to pass.
    address internal constant WITHDRAW_MANAGER = address(0xCAFE);

    /// @dev Submission window cutoff (`revealTime`) in the test harness; chosen well above
    ///      the default forge block.timestamp so the window is open by default.
    uint256 internal constant REVEAL_TIME = 1_000_000_000;

    TermFinanceBidFuseHarness internal harness;
    MockTermController internal controller;
    MockTermRepoServicer internal servicer;
    MockTermAuctionBidLocker internal bidLocker;
    MockERC20Decimals internal usdc;
    MockERC20Decimals internal weth;
    MockERC20Decimals internal wsteth;
    address internal termRepoLocker;
    address internal collateralManager;

    function setUp() public {
        controller = new MockTermController();
        harness = new TermFinanceBidFuseHarness(MARKET_ID, address(controller));

        usdc = new MockERC20Decimals("USDC", "USDC", 6);
        weth = new MockERC20Decimals("WETH", "WETH", 18);
        wsteth = new MockERC20Decimals("wstETH", "wstETH", 18);

        servicer = new MockTermRepoServicer();
        bidLocker = new MockTermAuctionBidLocker();
        termRepoLocker = makeAddr("termRepoLocker");
        collateralManager = makeAddr("collateralManager");

        servicer.setTermRepoLocker(termRepoLocker);
        servicer.setTermRepoCollateralManager(collateralManager);
        servicer.setPurchaseToken(address(usdc));

        bidLocker.setTermRepoServicer(address(servicer));
        bidLocker.setPurchaseToken(address(usdc));
        bidLocker.setRevealTime(REVEAL_TIME);
        bidLocker.setAuctionEndTime(REVEAL_TIME + 1 hours);

        controller.setIsTermDeployed(address(servicer), true);
        controller.setIsTermDeployed(address(bidLocker), true); // locker must be Term-deployed

        _grantSubstrates(address(servicer), _collateralTokens());

        // Fund the vault (harness acts as the vault).
        usdc.mint(address(harness), 100_000_000_000);
        weth.mint(address(harness), 1_000 ether);
        wsteth.mint(address(harness), 1_000 ether);

        // Default: WithdrawManager is configured.
        _setWithdrawManager(WITHDRAW_MANAGER);

        // Default: block.timestamp well below revealTime so the submission window is open.
        vm.warp(REVEAL_TIME - 1 days);
    }

    // ============ helpers ============

    function _setWithdrawManager(address manager_) internal {
        vm.store(address(harness), WITHDRAW_MANAGER_SLOT, bytes32(uint256(uint160(manager_))));
    }

    function _collateralTokens() internal view returns (address[] memory tokens) {
        tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(wsteth);
    }

    function _grantSubstrates(address servicer_, address[] memory collateralTokens_) internal {
        // Servicer + (servicer, collateralToken) pairs as a single substrate list.
        bytes32[] memory subs = new bytes32[](1 + collateralTokens_.length);
        subs[0] = PlasmaVaultConfigLib.addressToBytes32(servicer_);
        for (uint256 i; i < collateralTokens_.length; ++i) {
            subs[i + 1] = TermFinanceSubstrateLib.collateralPairKey(servicer_, collateralTokens_[i]);
        }
        harness.setMarketSubstrates(MARKET_ID, subs);
    }

    function _enterData(
        uint256 amt_,
        bytes32 hash_,
        bytes32 existingId_,
        address[] memory tokens_,
        uint256[] memory amounts_
    ) internal view returns (TermFinanceBidFuseEnterData memory) {
        return
            TermFinanceBidFuseEnterData({
                servicer: address(servicer),
                bidLocker: address(bidLocker),
                collateralManager: collateralManager,
                amount: amt_,
                bidPriceHash: hash_,
                existingBidId: existingId_,
                collateralTokens: tokens_,
                collateralAmounts: amounts_
            });
    }

    function _exitData(bytes32[] memory ids_) internal view returns (TermFinanceBidFuseExitData memory) {
        return
            TermFinanceBidFuseExitData({
                servicer: address(servicer),
                bidLocker: address(bidLocker),
                bidIds: ids_
            });
    }

    function _defaultEnterData(uint256 amt_, bytes32 hash_, bytes32 existingId_)
        internal
        view
        returns (TermFinanceBidFuseEnterData memory)
    {
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(wsteth);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;
        return _enterData(amt_, hash_, existingId_, tokens, amounts);
    }

    // ============ constructor ============

    function testConstructorShouldSetImmutables() public view {
        assertEq(harness.MARKET_ID(), MARKET_ID, "market id");
        assertEq(harness.TERM_CONTROLLER(), address(controller), "term controller");
        assertEq(harness.VERSION(), address(harness), "version");
    }

    function testConstructorShouldRevertOnZeroMarketId() public {
        vm.expectRevert(Errors.WrongValue.selector);
        new TermFinanceBidFuseHarness(0, address(controller));
    }

    function testConstructorShouldRevertOnZeroController() public {
        vm.expectRevert(Errors.WrongAddress.selector);
        new TermFinanceBidFuseHarness(MARKET_ID, address(0));
    }

    /// @notice Regression: constructor MUST NOT contain the WithdrawManager check.
    function testConstructorShouldNotRevertWhenWithdrawManagerIsZero() public {
        // No vm.store of WITHDRAW_MANAGER_SLOT — fresh deployment runs in a context where
        // the slot is empty. Plain new'ing the harness must succeed.
        TermFinanceBidFuseHarness fresh = new TermFinanceBidFuseHarness(MARKET_ID, address(controller));
        assertEq(fresh.MARKET_ID(), MARKET_ID);
    }

    // ============ enter — happy path ============

    function testEnterShouldLockBidAndStorePending() public {
        uint256 amt = 1_000_000_000;
        bytes32 hash_ = keccak256("hash-1");
        bytes32 expectedId = bytes32(uint256(0x1));

        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(wsteth);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;

        vm.expectEmit(true, true, true, true);
        emit TermFinanceBidLocked(
            address(harness),
            address(servicer),
            address(bidLocker),
            expectedId,
            amt,
            hash_,
            tokens,
            amounts
        );
        harness.enter(_enterData(amt, hash_, bytes32(0), tokens, amounts));

        assertTrue(harness.isBidPending(address(servicer), expectedId), "pending entry written");

        (
            address[] memory lockers,
            bytes32[] memory ids,
            uint256[] memory storedAmounts,
            address[][] memory storedTokens,
            uint256[][] memory storedCollateralAmounts
        ) = harness.getPendingBidsForServicer(address(servicer));

        assertEq(lockers.length, 1, "single bid tracked");
        assertEq(lockers[0], address(bidLocker), "bound bidLocker");
        assertEq(ids[0], expectedId, "bid id");
        assertEq(storedAmounts[0], amt, "amount");
        assertEq(storedTokens[0].length, 2, "two collateral tokens");
        assertEq(storedTokens[0][0], address(weth));
        assertEq(storedTokens[0][1], address(wsteth));
        assertEq(storedCollateralAmounts[0][0], 1 ether);
        assertEq(storedCollateralAmounts[0][1], 2 ether);
    }

    function testEnterShouldEditBidWhenExistingBidIdProvided() public {
        harness.enter(_defaultEnterData(1_000_000_000, keccak256("h"), bytes32(0)));
        bytes32 firstId = bytes32(uint256(0x1));
        assertTrue(harness.isBidPending(address(servicer), firstId), "first bid tracked");

        // Edit-flow: pass firstId as existingBidId. The mock reuses the supplied id
        // when non-zero, matching the on-chain BidLocker semantics for the edit path.
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 3 ether;
        harness.enter(_enterData(2_000_000_000, keccak256("h2"), firstId, tokens, amounts));

        // Length unchanged — in-place refresh.
        assertEq(harness.pendingBidsLength(address(servicer)), 1, "length unchanged on edit");

        (, bytes32[] memory ids, uint256[] memory storedAmounts, address[][] memory storedTokens, ) = harness
            .getPendingBidsForServicer(address(servicer));
        assertEq(ids[0], firstId, "same id");
        assertEq(storedAmounts[0], 2_000_000_000, "refreshed amount");
        assertEq(storedTokens[0].length, 1, "refreshed collateral tokens count");
        assertEq(storedTokens[0][0], address(weth));
    }

    function testEnterShouldClearApprovalsAfterLock() public {
        harness.enter(_defaultEnterData(1_000_000_000, keccak256("h"), bytes32(0)));
        assertEq(usdc.allowance(address(harness), termRepoLocker), 0, "usdc allowance cleared");
        assertEq(weth.allowance(address(harness), termRepoLocker), 0, "weth allowance cleared");
        assertEq(wsteth.allowance(address(harness), termRepoLocker), 0, "wsteth allowance cleared");
        // Negative: bidLocker must NEVER receive approval — funds flow through termRepoLocker.
        assertEq(usdc.allowance(address(harness), address(bidLocker)), 0, "must not approve bidLocker");
        assertEq(weth.allowance(address(harness), address(bidLocker)), 0);
    }

    function testEnterShouldHandleMultipleCollateralTokens() public {
        // 3 collateral tokens in a single bid.
        MockERC20Decimals wbtc = new MockERC20Decimals("WBTC", "WBTC", 8);
        wbtc.mint(address(harness), 100e8);

        // Add wbtc as allowlisted collateral pair.
        bytes32[] memory subs = new bytes32[](4);
        subs[0] = PlasmaVaultConfigLib.addressToBytes32(address(servicer));
        subs[1] = TermFinanceSubstrateLib.collateralPairKey(address(servicer), address(weth));
        subs[2] = TermFinanceSubstrateLib.collateralPairKey(address(servicer), address(wsteth));
        subs[3] = TermFinanceSubstrateLib.collateralPairKey(address(servicer), address(wbtc));
        harness.setMarketSubstrates(MARKET_ID, subs);

        address[] memory tokens = new address[](3);
        tokens[0] = address(weth);
        tokens[1] = address(wsteth);
        tokens[2] = address(wbtc);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1 ether;
        amounts[1] = 2 ether;
        amounts[2] = 0.5e8;

        harness.enter(_enterData(1_000_000_000, keccak256("h"), bytes32(0), tokens, amounts));

        bytes32 expectedId = bytes32(uint256(0x1));
        assertTrue(harness.isBidPending(address(servicer), expectedId), "tracked");
        (, , , address[][] memory storedTokens, ) = harness.getPendingBidsForServicer(address(servicer));
        assertEq(storedTokens[0].length, 3, "three collateral tokens recorded");
        // All approvals cleared.
        assertEq(weth.allowance(address(harness), termRepoLocker), 0);
        assertEq(wsteth.allowance(address(harness), termRepoLocker), 0);
        assertEq(wbtc.allowance(address(harness), termRepoLocker), 0);
    }

    // ============ exit — happy path ============

    function testExitShouldUnlockBidAndRemovePending() public {
        // Lock two bids first.
        harness.enter(_defaultEnterData(1_000_000_000, keccak256("h1"), bytes32(0)));
        harness.enter(_defaultEnterData(2_000_000_000, keccak256("h2"), bytes32(0)));

        bytes32 id1 = bytes32(uint256(0x1));
        bytes32 id2 = bytes32(uint256(0x2));
        assertTrue(harness.isBidPending(address(servicer), id1));
        assertTrue(harness.isBidPending(address(servicer), id2));

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;

        vm.expectEmit(true, true, true, true);
        emit TermFinanceBidUnlocked(address(harness), address(servicer), address(bidLocker), ids);
        harness.exit(_exitData(ids));

        assertFalse(harness.isBidPending(address(servicer), id1));
        assertFalse(harness.isBidPending(address(servicer), id2));
        assertEq(harness.pendingBidsLength(address(servicer)), 0, "all removed");
    }

    function testExitShouldNotRevertWhenBidIdNotInStorage() public {
        // storage remove is idempotent; the locker.unlockBids mock is also a no-op for
        // unknown ids — therefore exit with an unknown id must succeed silently.
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(0xDEAD));
        harness.exit(_exitData(ids));
        assertEq(harness.pendingBidsLength(address(servicer)), 0);
    }

    // ============ WithdrawManager runtime check ============

    function testEnterShouldRevertWhenWithdrawManagerIsZero() public {
        _setWithdrawManager(address(0));
        vm.expectRevert(TermFinanceBidFuse.TermFinanceBidFuseWithdrawManagerRequired.selector);
        harness.enter(_defaultEnterData(1_000_000_000, keccak256("h"), bytes32(0)));
    }

    function testExitShouldRevertWhenWithdrawManagerIsZero() public {
        _setWithdrawManager(address(0));
        bytes32[] memory ids = new bytes32[](0);
        vm.expectRevert(TermFinanceBidFuse.TermFinanceBidFuseWithdrawManagerRequired.selector);
        harness.exit(_exitData(ids));
    }

    /// @notice Ordering: WithdrawManager check runs FIRST, before substrate / pairing
    ///         / timing checks. With WithdrawManager zeroed and substrates wiped, the
    ///         revert must be the WithdrawManager selector (not Unsupported).
    function testEnterShouldCheckWithdrawManagerBeforeOtherValidation() public {
        _setWithdrawManager(address(0));
        bytes32[] memory empty = new bytes32[](0);
        harness.setMarketSubstrates(MARKET_ID, empty);
        vm.expectRevert(TermFinanceBidFuse.TermFinanceBidFuseWithdrawManagerRequired.selector);
        harness.enter(_defaultEnterData(1_000_000_000, keccak256("h"), bytes32(0)));
    }

    // ============ Substrate validation ============

    function testEnterShouldRevertWhenServicerSubstrateNotGranted() public {
        bytes32[] memory empty = new bytes32[](0);
        harness.setMarketSubstrates(MARKET_ID, empty);
        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBidFuse.TermFinanceBidFuseUnsupportedMarket.selector,
                address(servicer)
            )
        );
        harness.enter(_defaultEnterData(1_000_000_000, keccak256("h"), bytes32(0)));
    }

    function testEnterShouldRevertWhenCollateralTokenSubstrateNotGranted() public {
        // Re-grant ONLY the servicer substrate; remove collateral pair substrates.
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = PlasmaVaultConfigLib.addressToBytes32(address(servicer));
        harness.setMarketSubstrates(MARKET_ID, subs);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBidFuse.TermFinanceBidFuseUnsupportedCollateral.selector,
                address(servicer),
                address(weth)
            )
        );
        harness.enter(_defaultEnterData(1_000_000_000, keccak256("h"), bytes32(0)));
    }

    // ============ TermController ============

    function testEnterShouldRevertWhenTermNotDeployed() public {
        controller.setIsTermDeployed(address(servicer), false);
        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBidFuse.TermFinanceBidFuseTermNotDeployed.selector,
                address(servicer)
            )
        );
        harness.enter(_defaultEnterData(1_000_000_000, keccak256("h"), bytes32(0)));
    }

    // ============ BidLocker pairing ============

    /// @notice A spoofed bidLocker that returns the real granted servicer (so it
    ///         would pass the `termRepoServicer()` pairing) but is NOT registered with the Term
    ///         controller is rejected — preventing the phantom-pending-bid NAV inflation.
    function testEnterShouldRevertWhenBidLockerNotDeployed() public {
        MockTermAuctionBidLocker spoof = new MockTermAuctionBidLocker();
        spoof.setTermRepoServicer(address(servicer)); // would pass the pairing check
        spoof.setPurchaseToken(address(usdc));
        spoof.setRevealTime(REVEAL_TIME);
        // NOT flagged via controller.setIsTermDeployed(spoof, true).

        TermFinanceBidFuseEnterData memory data = _defaultEnterData(1_000_000_000, keccak256("h"), bytes32(0));
        data.bidLocker = address(spoof);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBidFuse.TermFinanceBidFuseBidLockerNotDeployed.selector,
                address(spoof)
            )
        );
        harness.enter(data);
    }

    /// @notice A borrower bid must NOT approve the purchase (loan) token to the
    ///         locker — it locks collateral and receives the loan. We block any
    ///         `usdc.approve(termRepoLocker, *)` call; the bid still succeeds because the fuse
    ///         never approves the purchase token (only collateral). Pre-fix this reverted.
    function testEnterDoesNotApprovePurchaseToken() public {
        vm.mockCallRevert(
            address(usdc),
            abi.encodeWithSelector(bytes4(keccak256("approve(address,uint256)")), termRepoLocker),
            bytes("purchase-token approve must not be called")
        );

        // Succeeds: only collateral (weth/wsteth) is approved; usdc.approve is never invoked.
        harness.enter(_defaultEnterData(1_000_000_000, keccak256("h"), bytes32(0)));

        bytes32 bidId = bytes32(uint256(0x1));
        assertTrue(harness.isBidPending(address(servicer), bidId), "bid locked without purchase-token approval");
    }

    function testEnterShouldRevertWhenBidLockerMismatch() public {
        // Wire bidLocker to a DIFFERENT servicer (returns address with non-matching value).
        MockTermRepoServicer other = new MockTermRepoServicer();
        bidLocker.setTermRepoServicer(address(other));

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBidFuse.TermFinanceBidFuseBidLockerMismatch.selector,
                address(servicer),
                address(other),
                address(servicer)
            )
        );
        harness.enter(_defaultEnterData(1_000_000_000, keccak256("h"), bytes32(0)));
    }

    function testExitShouldRevertWhenBidLockerMismatch() public {
        MockTermRepoServicer other = new MockTermRepoServicer();
        bidLocker.setTermRepoServicer(address(other));
        bytes32[] memory ids = new bytes32[](0);
        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBidFuse.TermFinanceBidFuseBidLockerMismatch.selector,
                address(servicer),
                address(other),
                address(servicer)
            )
        );
        harness.exit(_exitData(ids));
    }

    function testExitShouldRevertWhenServicerSubstrateNotGranted() public {
        bytes32[] memory empty = new bytes32[](0);
        harness.setMarketSubstrates(MARKET_ID, empty);
        bytes32[] memory ids = new bytes32[](0);
        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBidFuse.TermFinanceBidFuseUnsupportedMarket.selector,
                address(servicer)
            )
        );
        harness.exit(_exitData(ids));
    }

    // ============ CollateralManager pairing ============

    function testEnterShouldRevertWhenServicerCollateralManagerMismatch() public {
        address forged = makeAddr("forgedCollateralManager");
        // Set servicer to expect a DIFFERENT collateralManager than is in calldata.
        servicer.setTermRepoCollateralManager(forged);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBidFuse.TermFinanceBidFuseServicerCollateralManagerMismatch.selector,
                address(servicer),
                forged,
                collateralManager
            )
        );
        harness.enter(_defaultEnterData(1_000_000_000, keccak256("h"), bytes32(0)));
    }

    // ============ Submission window ============

    function testEnterShouldRevertWhenSubmissionWindowClosed() public {
        // Warp AT revealTime — submission window is closed (>=).
        vm.warp(REVEAL_TIME);
        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBidFuse.TermFinanceBidFuseSubmissionWindowClosed.selector,
                REVEAL_TIME,
                REVEAL_TIME
            )
        );
        harness.enter(_defaultEnterData(1_000_000_000, keccak256("h"), bytes32(0)));
    }

    function testEnterShouldAcceptBidAtRevealTimeMinusOne() public {
        // Boundary: timestamp strictly less than revealTime is accepted.
        vm.warp(REVEAL_TIME - 1);
        harness.enter(_defaultEnterData(1_000_000_000, keccak256("h"), bytes32(0)));
        assertTrue(harness.isBidPending(address(servicer), bytes32(uint256(0x1))), "accepted at revealTime - 1");
    }

    // ============ Input validation ============

    function testEnterShouldRevertWhenAmountIsZero() public {
        vm.expectRevert(TermFinanceBidFuse.TermFinanceBidFuseZeroAmount.selector);
        harness.enter(_defaultEnterData(0, keccak256("h"), bytes32(0)));
    }

    function testEnterShouldRevertWhenArrayLengthMismatch() public {
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(wsteth);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 1 ether;

        vm.expectRevert(TermFinanceBidFuse.TermFinanceBidFuseArrayLengthMismatch.selector);
        harness.enter(_enterData(1_000_000_000, keccak256("h"), bytes32(0), tokens, amounts));
    }

    /// @notice Duplicate `collateralTokens` would let the per-token approval loop
    ///         overwrite the prior approval while pending-bid storage records the SUMMED
    ///         amount, causing NAV over-reporting against the actual locker balance.
    function test_enter_revertsOnDuplicateCollateralToken() public {
        address dup = address(weth);
        address[] memory tokens = new address[](2);
        tokens[0] = dup;
        tokens[1] = dup;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e18;
        amounts[1] = 50e18;

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBidFuse.TermFinanceBidFuseDuplicateCollateralToken.selector,
                dup
            )
        );
        harness.enter(_enterData(1_000_000_000, keccak256("h"), bytes32(0), tokens, amounts));
    }

    // ============ Lock result validation ============

    function testEnterShouldRevertWhenLockReturnsEmpty() public {
        bidLocker.setLockBidsReturnsEmpty(true);
        vm.expectRevert(
            abi.encodeWithSelector(TermFinanceBidFuse.TermFinanceBidFuseUnexpectedLockResult.selector, uint256(0))
        );
        harness.enter(_defaultEnterData(1_000_000_000, keccak256("h"), bytes32(0)));
    }

    function testEnterShouldRevertWhenLockReturnsExtraIds() public {
        bidLocker.setLockBidsReturnsExtra(true);
        vm.expectRevert(
            abi.encodeWithSelector(TermFinanceBidFuse.TermFinanceBidFuseUnexpectedLockResult.selector, uint256(2))
        );
        harness.enter(_defaultEnterData(1_000_000_000, keccak256("h"), bytes32(0)));
    }

    function testEnterShouldPropagateLockerRevert() public {
        bidLocker.setLockBidsReverts(true);
        vm.expectRevert(bytes("MockBidLocker: lockBids reverts"));
        harness.enter(_defaultEnterData(1_000_000_000, keccak256("h"), bytes32(0)));
    }

    // ============ Pending-bids cap ============

    /// @notice enter must revert with `TooManyPendingBids` when the post-insert
    ///         length exceeds `MAX_PENDING_BIDS_PER_SERVICER = 150`. Uses the real cap value
    ///         (not a reduced sample) for realism — the upstream BidLocker mirror is 150.
    function testEnterShouldRevertWhenPendingBidsExceedCap() public {
        uint256 cap = TermFinancePendingBidsStorageLib.MAX_PENDING_BIDS_PER_SERVICER;
        assertEq(cap, 150, "cap must be 150 (mirror of MAX_BID_COUNT)");

        // Fill exactly `cap` distinct bids.
        for (uint256 i; i < cap; ++i) {
            harness.enter(_defaultEnterData(1_000_000_000, keccak256(abi.encode("h", i)), bytes32(0)));
        }
        assertEq(harness.pendingBidsLength(address(servicer)), cap, "exactly cap bids tracked");

        // The next non-edit enter must revert with TooManyPendingBids(servicer, cap + 1).
        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBidFuse.TermFinanceBidFuseTooManyPendingBids.selector,
                address(servicer),
                cap + 1
            )
        );
        harness.enter(_defaultEnterData(1_000_000_000, keccak256("overflow"), bytes32(0)));

        // Revert atomically undoes the over-cap write — length stays at cap.
        assertEq(harness.pendingBidsLength(address(servicer)), cap, "length unchanged after revert");
    }

    /// @notice Edit-flow path is EXEMPT from the cap because
    ///         re-inserting an existing id is an in-place refresh (length unchanged).
    function testEnterShouldNotEnforceCapOnEditFlow() public {
        uint256 cap = TermFinancePendingBidsStorageLib.MAX_PENDING_BIDS_PER_SERVICER;

        // Fill the cap with sequentially-allocated ids (0x1..0x96).
        for (uint256 i; i < cap; ++i) {
            harness.enter(_defaultEnterData(1_000_000_000, keccak256(abi.encode("seed", i)), bytes32(0)));
        }
        assertEq(harness.pendingBidsLength(address(servicer)), cap, "cap reached");

        // Edit-flow at the cap: existingBidId = 0x1 (first allocated). Must succeed and
        // not increase the length (in-place refresh).
        bytes32 existing = bytes32(uint256(0x1));
        assertTrue(harness.isBidPending(address(servicer), existing), "first id present");

        harness.enter(_defaultEnterData(5_000_000_000, keccak256("edit"), existing));
        assertEq(harness.pendingBidsLength(address(servicer)), cap, "length unchanged on edit at cap");

        // Refresh: verify the amount was updated.
        (, bytes32[] memory ids, uint256[] memory amounts, , ) = harness.getPendingBidsForServicer(address(servicer));
        // Find the entry by id and verify amount.
        bool found;
        for (uint256 i; i < ids.length; ++i) {
            if (ids[i] == existing) {
                assertEq(amounts[i], 5_000_000_000, "refreshed amount on edit");
                found = true;
                break;
            }
        }
        assertTrue(found, "edited bid retained");
    }

    /// @notice A cap-breach enter must short-circuit BEFORE the external `lockBids`
    ///         call (no approval side-effects, no locker invocation). Uses
    ///         `vm.expectCall(..., 0)` because the bid-fuse reverts atomically — any state
    ///         counter on the mock would be rolled back regardless of whether `lockBids` was
    ///         entered. `expectCall` instead intercepts the call at the EVM boundary, so it
    ///         catches the invocation BEFORE the revert restores state.
    function testEnterCapBreachDoesNotInvokeLockBids() public {
        uint256 cap = TermFinancePendingBidsStorageLib.MAX_PENDING_BIDS_PER_SERVICER;

        // Fill exactly `cap` distinct bids via real enter() calls — keeps the bookkeeping
        // (storage + servicer registration) consistent with what the cap check reads.
        for (uint256 i; i < cap; ++i) {
            harness.enter(_defaultEnterData(1_000_000_000, keccak256(abi.encode("seed", i)), bytes32(0)));
        }
        assertEq(harness.pendingBidsLength(address(servicer)), cap, "cap reached");

        // Assert lockBids is NOT invoked on the bidLocker during the next enter() call.
        // The `count = 0` form of expectCall is what makes this meaningful — it does not
        // care about state-revert semantics.
        vm.expectCall(address(bidLocker), abi.encodeWithSelector(MockTermAuctionBidLocker.lockBids.selector), 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBidFuse.TermFinanceBidFuseTooManyPendingBids.selector,
                address(servicer),
                cap + 1
            )
        );
        harness.enter(_defaultEnterData(1_000_000_000, keccak256("overflow"), bytes32(0)));

        assertEq(harness.pendingBidsLength(address(servicer)), cap, "length unchanged after revert");
    }

    /// @notice Regression: at the cap, supplying a non-zero `existingBidId`
    ///         that is NOT tracked in storage MUST trigger the cap-check (storage would
    ///         grow because `removePendingBidIfExists` returns `false`). Pre-fix the
    ///         edit-flow branch was exempt unconditionally, so this path quietly
    ///         appended a new entry past the cap.
    function testEnterEditFlowWithFakeExistingBidIdBypassesCap() public {
        uint256 cap = TermFinancePendingBidsStorageLib.MAX_PENDING_BIDS_PER_SERVICER;

        for (uint256 i; i < cap; ++i) {
            harness.enter(_defaultEnterData(1_000_000_000, keccak256(abi.encode("seed", i)), bytes32(0)));
        }
        assertEq(harness.pendingBidsLength(address(servicer)), cap, "cap reached");

        // Unknown id: not present in storage. Pre-fix this bypassed the cap.
        bytes32 fake = keccak256("FAKE-EXISTING-ID");
        assertFalse(harness.isBidPending(address(servicer), fake), "fake id NOT tracked pre-call");

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBidFuse.TermFinanceBidFuseTooManyPendingBids.selector,
                address(servicer),
                cap + 1
            )
        );
        harness.enter(_defaultEnterData(1_000_000_000, keccak256("attack"), fake));

        assertEq(harness.pendingBidsLength(address(servicer)), cap, "length unchanged after attack");
    }

    /// @notice Paired with the bypass regression: edit-flow with a KNOWN
    ///         id must still be exempt — the `removed=true` branch lets length stay
    ///         unchanged. Ensures the fix did not regress the legitimate path.
    function testEnterEditFlowWithKnownExistingBidIdRespectsCapExemption() public {
        uint256 cap = TermFinancePendingBidsStorageLib.MAX_PENDING_BIDS_PER_SERVICER;

        for (uint256 i; i < cap; ++i) {
            harness.enter(_defaultEnterData(1_000_000_000, keccak256(abi.encode("seed", i)), bytes32(0)));
        }

        bytes32 known = bytes32(uint256(0x1));
        assertTrue(harness.isBidPending(address(servicer), known), "first id present");

        // Edit-flow at the cap with a real id — must succeed (in-place refresh).
        harness.enter(_defaultEnterData(2_000_000_000, keccak256("refresh"), known));

        assertEq(harness.pendingBidsLength(address(servicer)), cap, "length unchanged after refresh");
    }
}

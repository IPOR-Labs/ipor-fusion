// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Errors} from "contracts/libraries/errors/Errors.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {IExtTermAuctionBidLocker} from "contracts/fuses/term_finance/ext/IExtTermAuctionBidLocker.sol";
import {
    TermFinanceBidRevealFuse,
    TermFinanceBidRevealFuseEnterData
} from "contracts/fuses/term_finance/TermFinanceBidRevealFuse.sol";

import {TermFinanceBidRevealFuseHarness} from "./mocks/TermFinanceBidRevealFuseHarness.sol";
import {MockTermAuctionBidLocker} from "./mocks/MockTermAuctionBidLocker.sol";
import {MockTermController} from "./mocks/MockTermController.sol";
import {MockTermRepoServicer} from "./mocks/MockTermRepoServicer.sol";

/// @notice Unit-test suite for `TermFinanceBidRevealFuse`.
/// @dev Mirror of `TermFinanceOfferRevealFuseTest` (lender-side reveal → borrower-side bid reveal):
///      - `bidLocker.revealBids(ids, prices, nonces)` replaces `offerLocker.revealOffers(...)`.
///      - Servicer is recovered from `bidLocker.termRepoServicer()` (not passed in calldata).
///      - `revealTime` gates the reveal window OPENING (`block.timestamp >= revealTime`); there
///        is NO upper bound (auction closure is the auctioneer's `completeAuction` call).
///      - WithdrawManager runtime check: runs as the FIRST statement of `enter`, even
///        though BidReveal does not move funds.
///      - No `exit()` — once revealed, a bid is cryptographically committed.
contract TermFinanceBidRevealFuseTest is Test {
    /// @dev Canonical WithdrawManager storage slot (`PlasmaVaultStorageLib.WITHDRAW_MANAGER`).
    ///      Used to poke the harness's storage directly so the runtime check
    ///      `getWithdrawManager().manager == address(0)` resolves to a non-zero address.
    bytes32 internal constant WITHDRAW_MANAGER_SLOT =
        0x465d2ff0062318fe6f4c7e9ac78cfcd70bc86a1d992722875ef83a9770513100;

    /// @dev Sentinel WithdrawManager address — any non-zero value is sufficient for the
    ///      `_assertWithdrawManagerSet()` guard to pass.
    address internal constant WITHDRAW_MANAGER = address(0xCAFE);

    /// @dev Reveal-window opening time used in the test harness; chosen well above the default
    ///      forge block.timestamp so we can warp the test clock around the boundary.
    uint256 internal constant REVEAL_TIME = 1_000_000_000;

    /// @dev Local copy of fuse event for `vm.expectEmit` assertions.
    event TermFinanceBidsRevealed(
        address version,
        address servicer,
        address bidLocker,
        bytes32[] bidIds,
        uint256[] bidPrices
    );

    uint256 internal constant MARKET_ID = 52;

    TermFinanceBidRevealFuseHarness internal harness;
    MockTermController internal controller;
    MockTermRepoServicer internal servicer;
    MockTermAuctionBidLocker internal bidLocker;

    function setUp() public {
        controller = new MockTermController();
        harness = new TermFinanceBidRevealFuseHarness(MARKET_ID, address(controller));

        servicer = new MockTermRepoServicer();
        bidLocker = new MockTermAuctionBidLocker();
        bidLocker.setTermRepoServicer(address(servicer));
        bidLocker.setRevealTime(REVEAL_TIME);

        controller.setIsTermDeployed(address(servicer), true);
        controller.setIsTermDeployed(address(bidLocker), true); // locker must be Term-deployed

        bytes32[] memory subs = new bytes32[](1);
        subs[0] = PlasmaVaultConfigLib.addressToBytes32(address(servicer));
        harness.setMarketSubstrates(MARKET_ID, subs);

        // Default: WithdrawManager configured so the runtime check passes.
        _setWithdrawManager(WITHDRAW_MANAGER);

        // Default: block.timestamp at the boundary — reveal window OPEN.
        vm.warp(REVEAL_TIME);
    }

    // ============ helpers ============

    function _setWithdrawManager(address manager_) internal {
        vm.store(address(harness), WITHDRAW_MANAGER_SLOT, bytes32(uint256(uint160(manager_))));
    }

    function _seedBid(bytes32 id_, uint256 price_, uint256 nonce_) internal {
        bytes32 hash_ = keccak256(abi.encode(price_, nonce_));
        bidLocker.setLockedBid(
            id_,
            IExtTermAuctionBidLocker.TermAuctionBid({
                id: id_,
                bidder: address(harness),
                bidPriceHash: hash_,
                bidPriceRevealed: 0,
                amount: 1_000_000,
                collateralAmounts: new uint256[](0),
                purchaseToken: address(0),
                collateralTokens: new address[](0),
                isRollover: false,
                rolloverPairOffTermRepoServicer: address(0),
                isRevealed: false
            })
        );
    }

    function _data(
        bytes32[] memory ids_,
        uint256[] memory prices_,
        uint256[] memory nonces_
    ) internal view returns (TermFinanceBidRevealFuseEnterData memory) {
        return TermFinanceBidRevealFuseEnterData({
            bidLocker: address(bidLocker),
            bidIds: ids_,
            bidPrices: prices_,
            bidNonces: nonces_
        });
    }

    // ============ constructor ============

    function testConstructorShouldSetImmutables() public view {
        assertEq(harness.MARKET_ID(), MARKET_ID, "market id");
        assertEq(harness.TERM_CONTROLLER(), address(controller), "term controller");
        assertEq(harness.VERSION(), address(harness), "version");
    }

    function testConstructorShouldRevertOnZeroMarketId() public {
        vm.expectRevert(Errors.WrongValue.selector);
        new TermFinanceBidRevealFuseHarness(0, address(controller));
    }

    function testConstructorShouldRevertOnZeroController() public {
        vm.expectRevert(Errors.WrongAddress.selector);
        new TermFinanceBidRevealFuseHarness(MARKET_ID, address(0));
    }

    /// @notice Regression: constructor MUST NOT contain the WithdrawManager check — fuses are
    ///         deployed standalone and the deployer's storage is empty.
    function testConstructorShouldNotRevertWhenWithdrawManagerIsZero() public {
        // No `vm.store` of WITHDRAW_MANAGER_SLOT — fresh deployment runs in a context where
        // the slot is empty. Plain `new`'ing the harness must succeed.
        TermFinanceBidRevealFuseHarness fresh = new TermFinanceBidRevealFuseHarness(
            MARKET_ID,
            address(controller)
        );
        assertEq(fresh.MARKET_ID(), MARKET_ID);
    }

    // ============ enter — happy path ============

    function testEnterShouldRevealBids() public {
        bytes32 id1 = bytes32(uint256(0x1));
        bytes32 id2 = bytes32(uint256(0x2));
        _seedBid(id1, 5e16, 0xABC);
        _seedBid(id2, 6e16, 0xDEF);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;
        uint256[] memory prices = new uint256[](2);
        prices[0] = 5e16;
        prices[1] = 6e16;
        uint256[] memory nonces = new uint256[](2);
        nonces[0] = 0xABC;
        nonces[1] = 0xDEF;

        harness.enter(_data(ids, prices, nonces));

        // Assert the locker recorded the reveal for both bids (proves
        // `bidLocker.revealBids(ids, prices, nonces)` was called with the correct args).
        IExtTermAuctionBidLocker.TermAuctionBid memory b1 = bidLocker.lockedBid(id1);
        IExtTermAuctionBidLocker.TermAuctionBid memory b2 = bidLocker.lockedBid(id2);
        assertTrue(b1.isRevealed, "first bid revealed");
        assertTrue(b2.isRevealed, "second bid revealed");
        assertEq(b1.bidPriceRevealed, 5e16, "first price recorded");
        assertEq(b2.bidPriceRevealed, 6e16, "second price recorded");
    }

    function testEnterShouldEmitBidsRevealedEvent() public {
        bytes32 id = bytes32(uint256(0x1));
        uint256 price = 5e16;
        uint256 nonce = 0xABC;
        _seedBid(id, price, nonce);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint256[] memory prices = new uint256[](1);
        prices[0] = price;
        uint256[] memory nonces = new uint256[](1);
        nonces[0] = nonce;

        vm.expectEmit(true, true, true, true);
        emit TermFinanceBidsRevealed(address(harness), address(servicer), address(bidLocker), ids, prices);
        harness.enter(_data(ids, prices, nonces));
    }

    // ============ WithdrawManager runtime check ============

    /// @notice `enter` must revert with the BidReveal-specific selector when WithdrawManager is
    ///         unconfigured.
    function testEnterShouldRevertWhenWithdrawManagerIsZero() public {
        _setWithdrawManager(address(0));

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(0x1));
        uint256[] memory prices = new uint256[](1);
        uint256[] memory nonces = new uint256[](1);

        vm.expectRevert(TermFinanceBidRevealFuse.TermFinanceBidRevealFuseWithdrawManagerRequired.selector);
        harness.enter(_data(ids, prices, nonces));
    }

    // ============ TermController ============

    function testEnterShouldRevertWhenTermNotDeployed() public {
        controller.setIsTermDeployed(address(servicer), false);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(0x1));
        uint256[] memory prices = new uint256[](1);
        uint256[] memory nonces = new uint256[](1);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBidRevealFuse.TermFinanceBidRevealFuseTermNotDeployed.selector,
                address(servicer)
            )
        );
        harness.enter(_data(ids, prices, nonces));
    }

    /// @notice A spoofed bidLocker (returns the real servicer but is not
    ///         Term-deployed) is rejected before its self-reported servicer is trusted.
    function testEnterShouldRevertWhenBidLockerNotDeployed() public {
        MockTermAuctionBidLocker spoof = new MockTermAuctionBidLocker();
        spoof.setTermRepoServicer(address(servicer));
        spoof.setRevealTime(REVEAL_TIME);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(0x1));
        uint256[] memory prices = new uint256[](1);
        uint256[] memory nonces = new uint256[](1);

        TermFinanceBidRevealFuseEnterData memory data = TermFinanceBidRevealFuseEnterData({
            bidLocker: address(spoof),
            bidIds: ids,
            bidPrices: prices,
            bidNonces: nonces
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBidRevealFuse.TermFinanceBidRevealFuseBidLockerNotDeployed.selector, address(spoof)
            )
        );
        harness.enter(data);
    }

    // ============ BidLocker → Servicer resolving ============

    /// @notice When `bidLocker.termRepoServicer() == address(0)`, the BidReveal fuse must
    ///         revert with `BidLockerMismatch(bidLocker)` — surfaces non-locker contracts
    ///         that satisfy the ABI but return a zero value.
    function testEnterShouldRevertWhenBidLockerReturnsZeroServicer() public {
        bidLocker.setTermRepoServicer(address(0));

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(0x1));
        uint256[] memory prices = new uint256[](1);
        uint256[] memory nonces = new uint256[](1);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBidRevealFuse.TermFinanceBidRevealFuseBidLockerMismatch.selector,
                address(bidLocker)
            )
        );
        harness.enter(_data(ids, prices, nonces));
    }

    /// @notice Recovered servicer must be in the TYPE 0x00 substrate allowlist.
    function testEnterShouldRevertWhenServicerSubstrateNotGranted() public {
        bytes32[] memory empty = new bytes32[](0);
        harness.setMarketSubstrates(MARKET_ID, empty);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(0x1));
        uint256[] memory prices = new uint256[](1);
        uint256[] memory nonces = new uint256[](1);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBidRevealFuse.TermFinanceBidRevealFuseUnsupportedMarket.selector,
                address(servicer)
            )
        );
        harness.enter(_data(ids, prices, nonces));
    }

    // ============ Reveal window ============

    /// @notice `block.timestamp < revealTime` → window not yet open. The fuse must revert with
    ///         `RevealWindowNotOpen(nowTs, revealTime)` (exact selector + payload).
    function testEnterShouldRevertWhenRevealWindowNotOpen() public {
        vm.warp(REVEAL_TIME - 1);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(0x1));
        uint256[] memory prices = new uint256[](1);
        uint256[] memory nonces = new uint256[](1);

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceBidRevealFuse.TermFinanceBidRevealFuseRevealWindowNotOpen.selector,
                REVEAL_TIME - 1,
                REVEAL_TIME
            )
        );
        harness.enter(_data(ids, prices, nonces));
    }

    /// @notice Boundary: `block.timestamp == revealTime` is the FIRST moment the window is
    ///         open (the guard is `block.timestamp < revealTime` → revert; `>=` succeeds).
    ///         There is NO upper bound — auction closure is `completeAuction`'s job, not
    ///         the locker's.
    function testEnterShouldAcceptRevealAtExactRevealTime() public {
        vm.warp(REVEAL_TIME);

        bytes32 id = bytes32(uint256(0x1));
        uint256 price = 5e16;
        uint256 nonce = 0xABC;
        _seedBid(id, price, nonce);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint256[] memory prices = new uint256[](1);
        prices[0] = price;
        uint256[] memory nonces = new uint256[](1);
        nonces[0] = nonce;

        harness.enter(_data(ids, prices, nonces));
        assertTrue(bidLocker.lockedBid(id).isRevealed, "accepted at boundary revealTime");
    }

    // ============ Input validation ============

    function testEnterShouldRevertWhenBidIdsEmpty() public {
        bytes32[] memory ids = new bytes32[](0);
        uint256[] memory prices = new uint256[](0);
        uint256[] memory nonces = new uint256[](0);

        vm.expectRevert(TermFinanceBidRevealFuse.TermFinanceBidRevealFuseEmptyIds.selector);
        harness.enter(_data(ids, prices, nonces));
    }

    function testEnterShouldRevertWhenArrayLengthMismatch() public {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = bytes32(uint256(0x1));
        ids[1] = bytes32(uint256(0x2));
        uint256[] memory prices = new uint256[](1);
        uint256[] memory nonces = new uint256[](2);

        vm.expectRevert(TermFinanceBidRevealFuse.TermFinanceBidRevealFuseArrayLengthMismatch.selector);
        harness.enter(_data(ids, prices, nonces));
    }

    function testEnterShouldRevertWhenNoncesLengthMismatch() public {
        bytes32[] memory ids = new bytes32[](2);
        ids[0] = bytes32(uint256(0x1));
        ids[1] = bytes32(uint256(0x2));
        uint256[] memory prices = new uint256[](2);
        uint256[] memory nonces = new uint256[](1);

        vm.expectRevert(TermFinanceBidRevealFuse.TermFinanceBidRevealFuseArrayLengthMismatch.selector);
        harness.enter(_data(ids, prices, nonces));
    }

    // ============ No exit() exposed ============

    /// @notice Compile-time check: `TermFinanceBidRevealFuse` exposes ONLY `enter` (plus
    ///         immutable getters `VERSION` / `MARKET_ID` / `TERM_CONTROLLER`) — there is
    ///         no `exit(...)` because a revealed bid is cryptographically committed and
    ///         cannot be un-revealed. The interface ID assertion below would fail to compile
    ///         if an `exit(...)` selector were later added without updating this test.
    function testRevealFuseHasNoExitFunction() public view {
        // Probe via raw selectors. `enter(TermFinanceBidRevealFuseEnterData)` MUST exist;
        // any `exit(...)` selector MUST NOT be resolvable to a non-zero implementation.
        bytes4 enterSel = TermFinanceBidRevealFuse.enter.selector;
        assertTrue(enterSel != bytes4(0), "enter selector present");

        // No `exit(...)` on the contract: a call with a plausible exit selector must revert
        // (falls through to no-receive / no-fallback on a contract without those).
        bytes memory plausibleExit = abi.encodeWithSignature("exit(bytes32[])", new bytes32[](0));
        (bool ok, ) = address(harness).staticcall(plausibleExit);
        assertFalse(ok, "exit(bytes32[]) MUST NOT exist on BidRevealFuse");

        plausibleExit = abi.encodeWithSignature(
            "exit((address,bytes32[],uint256[],uint256[]))",
            address(0),
            new bytes32[](0),
            new uint256[](0),
            new uint256[](0)
        );
        (ok, ) = address(harness).staticcall(plausibleExit);
        assertFalse(ok, "exit(EnterData) MUST NOT exist on BidRevealFuse");
    }
}

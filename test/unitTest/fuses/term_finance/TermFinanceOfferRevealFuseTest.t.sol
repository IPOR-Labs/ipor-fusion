// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Errors} from "contracts/libraries/errors/Errors.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {IExtTermAuctionOfferLocker} from "contracts/fuses/term_finance/ext/IExtTermAuctionOfferLocker.sol";
import {
    TermFinanceOfferRevealFuse,
    TermFinanceOfferRevealFuseEnterData
} from "contracts/fuses/term_finance/TermFinanceOfferRevealFuse.sol";

import {TermFinanceOfferRevealFuseHarness} from "./mocks/TermFinanceOfferRevealFuseHarness.sol";
import {MockTermAuctionOfferLocker} from "./mocks/MockTermAuctionOfferLocker.sol";
import {MockTermController} from "./mocks/MockTermController.sol";
import {MockTermRepoServicer} from "./mocks/MockTermRepoServicer.sol";

contract TermFinanceOfferRevealFuseTest is Test {
    /// @dev Local copy of fuse event for `vm.expectEmit` assertions.
    event TermFinanceOffersRevealed(
        address version,
        address servicer,
        address offerLocker,
        bytes32[] offerIds,
        uint256[] prices
    );

    uint256 internal constant MARKET_ID = 52;

    /// @dev Canonical WithdrawManager ERC-7201 slot — mirrors `PlasmaVaultStorageLib`'s
    ///      `WITHDRAW_MANAGER` constant (private there).
    bytes32 internal constant WITHDRAW_MANAGER_SLOT =
        0x465d2ff0062318fe6f4c7e9ac78cfcd70bc86a1d992722875ef83a9770513100;

    /// @dev Sentinel WithdrawManager address — any non-zero value satisfies the guard.
    address internal constant WITHDRAW_MANAGER = address(0xCAFE);

    TermFinanceOfferRevealFuseHarness harness;
    MockTermController controller;
    MockTermRepoServicer servicer;
    MockTermAuctionOfferLocker offerLocker;

    function setUp() public {
        controller = new MockTermController();
        harness = new TermFinanceOfferRevealFuseHarness(MARKET_ID, address(controller));

        servicer = new MockTermRepoServicer();
        offerLocker = new MockTermAuctionOfferLocker();
        offerLocker.setTermRepoServicer(address(servicer));
        controller.setIsTermDeployed(address(servicer), true);
        controller.setIsTermDeployed(address(offerLocker), true); // locker must be Term-deployed

        bytes32[] memory subs = new bytes32[](1);
        subs[0] = PlasmaVaultConfigLib.addressToBytes32(address(servicer));
        harness.setMarketSubstrates(MARKET_ID, subs);

        // Default: WithdrawManager is configured (invariant satisfied).
        _setWithdrawManager(WITHDRAW_MANAGER);
    }

    function _setWithdrawManager(address manager_) internal {
        vm.store(address(harness), WITHDRAW_MANAGER_SLOT, bytes32(uint256(uint160(manager_))));
    }

    function _clearWithdrawManagerSlot() internal {
        _setWithdrawManager(address(0));
    }

    function _seedOffer(bytes32 id_, uint256 price_, uint256 nonce_) internal {
        bytes32 hash_ = keccak256(abi.encode(price_, nonce_));
        offerLocker.setLockedOffer(
            id_,
            IExtTermAuctionOfferLocker.TermAuctionOffer({
                id: id_,
                offeror: address(harness),
                offerPriceHash: hash_,
                offerPriceRevealed: 0,
                amount: 1_000_000,
                purchaseToken: address(0),
                isRevealed: false
            })
        );
    }

    function _data(
        bytes32[] memory ids_,
        uint256[] memory prices_,
        uint256[] memory nonces_
    ) internal view returns (TermFinanceOfferRevealFuseEnterData memory) {
        return TermFinanceOfferRevealFuseEnterData({
            servicer: address(servicer),
            offerLocker: address(offerLocker),
            offerIds: ids_,
            prices: prices_,
            nonces: nonces_
        });
    }

    // ============ constructor ============

    function test_constructor_setsImmutables() public view {
        assertEq(harness.MARKET_ID(), MARKET_ID);
        assertEq(harness.TERM_CONTROLLER(), address(controller));
    }

    function test_constructor_revertsOnZeroMarketId() public {
        vm.expectRevert(Errors.WrongValue.selector);
        new TermFinanceOfferRevealFuseHarness(0, address(controller));
    }

    function test_constructor_revertsOnZeroController() public {
        vm.expectRevert(Errors.WrongAddress.selector);
        new TermFinanceOfferRevealFuseHarness(MARKET_ID, address(0));
    }

    // ============ enter — happy path ============

    function test_enter_happyPath_singleOffer() public {
        bytes32 id = bytes32(uint256(0x1));
        uint256 price = 5e16;
        uint256 nonce = 0xABC;
        _seedOffer(id, price, nonce);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint256[] memory prices = new uint256[](1);
        prices[0] = price;
        uint256[] memory nonces = new uint256[](1);
        nonces[0] = nonce;

        // Assert full event payload.
        vm.expectEmit(true, true, true, true);
        emit TermFinanceOffersRevealed(address(harness), address(servicer), address(offerLocker), ids, prices);
        harness.enter(_data(ids, prices, nonces));

        IExtTermAuctionOfferLocker.TermAuctionOffer memory offer = offerLocker.lockedOffer(id);
        assertTrue(offer.isRevealed);
        assertEq(offer.offerPriceRevealed, price);
    }

    function test_enter_happyPath_multipleOffers() public {
        bytes32 id1 = bytes32(uint256(0x1));
        bytes32 id2 = bytes32(uint256(0x2));
        _seedOffer(id1, 5e16, 0x1);
        _seedOffer(id2, 6e16, 0x2);

        bytes32[] memory ids = new bytes32[](2);
        ids[0] = id1;
        ids[1] = id2;
        uint256[] memory prices = new uint256[](2);
        prices[0] = 5e16;
        prices[1] = 6e16;
        uint256[] memory nonces = new uint256[](2);
        nonces[0] = 0x1;
        nonces[1] = 0x2;

        harness.enter(_data(ids, prices, nonces));

        assertTrue(offerLocker.lockedOffer(id1).isRevealed);
        assertTrue(offerLocker.lockedOffer(id2).isRevealed);
    }

    // ============ enter — guards ============

    function test_enter_revertsOnSubstrateNotGranted() public {
        bytes32[] memory empty = new bytes32[](0);
        harness.setMarketSubstrates(MARKET_ID, empty);

        bytes32[] memory ids = new bytes32[](1);
        uint256[] memory prices = new uint256[](1);
        uint256[] memory nonces = new uint256[](1);
        ids[0] = bytes32(uint256(1));

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceOfferRevealFuse.TermFinanceOfferRevealFuseUnsupportedMarket.selector,
                address(servicer)
            )
        );
        harness.enter(_data(ids, prices, nonces));
    }

    function test_enter_revertsOnControllerNotDeployed() public {
        controller.setIsTermDeployed(address(servicer), false);

        bytes32[] memory ids = new bytes32[](1);
        uint256[] memory prices = new uint256[](1);
        uint256[] memory nonces = new uint256[](1);
        ids[0] = bytes32(uint256(1));

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceOfferRevealFuse.TermFinanceOfferRevealFuseTermNotDeployed.selector,
                address(servicer)
            )
        );
        harness.enter(_data(ids, prices, nonces));
    }

    /// @notice A spoofed offerLocker (returns the real servicer but is not
    ///         Term-deployed) is rejected before `revealOffers`.
    function test_enter_revertsOnSpoofedLockerNotDeployed() public {
        MockTermAuctionOfferLocker spoof = new MockTermAuctionOfferLocker();
        spoof.setTermRepoServicer(address(servicer));

        bytes32[] memory ids = new bytes32[](1);
        uint256[] memory prices = new uint256[](1);
        uint256[] memory nonces = new uint256[](1);
        ids[0] = bytes32(uint256(1));

        TermFinanceOfferRevealFuseEnterData memory data = TermFinanceOfferRevealFuseEnterData({
            servicer: address(servicer),
            offerLocker: address(spoof),
            offerIds: ids,
            prices: prices,
            nonces: nonces
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceOfferRevealFuse.TermFinanceOfferRevealFuseOfferLockerNotDeployed.selector, address(spoof)
            )
        );
        harness.enter(data);
    }

    function test_enter_revertsOnOfferLockerMismatch() public {
        MockTermRepoServicer other = new MockTermRepoServicer();
        offerLocker.setTermRepoServicer(address(other));

        bytes32[] memory ids = new bytes32[](1);
        uint256[] memory prices = new uint256[](1);
        uint256[] memory nonces = new uint256[](1);
        ids[0] = bytes32(uint256(1));

        // Assert full (expected, actual) payload, not just selector.
        vm.expectRevert(
            abi.encodeWithSelector(
                TermFinanceOfferRevealFuse.TermFinanceOfferRevealFuseOfferLockerMismatch.selector,
                address(other),
                address(servicer)
            )
        );
        harness.enter(_data(ids, prices, nonces));
    }

    function test_enter_revertsOnEmptyIds() public {
        bytes32[] memory ids = new bytes32[](0);
        uint256[] memory prices = new uint256[](0);
        uint256[] memory nonces = new uint256[](0);

        vm.expectRevert(TermFinanceOfferRevealFuse.TermFinanceOfferRevealFuseEmptyIds.selector);
        harness.enter(_data(ids, prices, nonces));
    }

    function test_enter_revertsOnPricesLengthMismatch() public {
        bytes32[] memory ids = new bytes32[](2);
        uint256[] memory prices = new uint256[](1);
        uint256[] memory nonces = new uint256[](2);
        ids[0] = bytes32(uint256(1));
        ids[1] = bytes32(uint256(2));

        vm.expectRevert(TermFinanceOfferRevealFuse.TermFinanceOfferRevealFuseArrayLengthMismatch.selector);
        harness.enter(_data(ids, prices, nonces));
    }

    function test_enter_revertsOnNoncesLengthMismatch() public {
        bytes32[] memory ids = new bytes32[](2);
        uint256[] memory prices = new uint256[](2);
        uint256[] memory nonces = new uint256[](1);
        ids[0] = bytes32(uint256(1));
        ids[1] = bytes32(uint256(2));

        vm.expectRevert(TermFinanceOfferRevealFuse.TermFinanceOfferRevealFuseArrayLengthMismatch.selector);
        harness.enter(_data(ids, prices, nonces));
    }

    function test_enter_propagatesHashMismatch() public {
        bytes32 id = bytes32(uint256(0x1));
        _seedOffer(id, 5e16, 0xABC);

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = id;
        uint256[] memory prices = new uint256[](1);
        prices[0] = 9e16; // wrong rate
        uint256[] memory nonces = new uint256[](1);
        nonces[0] = 0xABC;

        vm.expectRevert(bytes("hash mismatch"));
        harness.enter(_data(ids, prices, nonces));
    }

    // ============ WithdrawManager runtime check ============

    function test_enter_revertsWhenWithdrawManagerNotSet() public {
        _clearWithdrawManagerSlot();

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(0x1));
        uint256[] memory prices = new uint256[](1);
        prices[0] = 5e16;
        uint256[] memory nonces = new uint256[](1);
        nonces[0] = 0xABC;

        vm.expectRevert(TermFinanceOfferRevealFuse.TermFinanceOfferRevealFuseWithdrawManagerRequired.selector);
        harness.enter(_data(ids, prices, nonces));
    }

    /// @notice Ordering: WithdrawManager check runs FIRST, before the substrate allowlist
    ///         check (`_isMarketSubstrateGranted`, which would otherwise revert with
    ///         `UnsupportedMarket`). With both invariants broken, the revert must be the
    ///         WithdrawManager selector — proving a single-position reorder would be caught.
    function testEnterShouldCheckWithdrawManagerBeforeOtherValidation() public {
        bytes32[] memory empty = new bytes32[](0);
        harness.setMarketSubstrates(MARKET_ID, empty);
        _clearWithdrawManagerSlot();

        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(0x1));
        uint256[] memory prices = new uint256[](1);
        prices[0] = 5e16;
        uint256[] memory nonces = new uint256[](1);
        nonces[0] = 0xABC;

        vm.expectRevert(TermFinanceOfferRevealFuse.TermFinanceOfferRevealFuseWithdrawManagerRequired.selector);
        harness.enter(_data(ids, prices, nonces));
    }
}

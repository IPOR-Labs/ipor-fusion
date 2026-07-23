// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Errors} from "../../libraries/errors/Errors.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "../../libraries/PlasmaVaultStorageLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IExtTermAuctionBidLocker} from "./ext/IExtTermAuctionBidLocker.sol";
import {IExtTermController} from "./ext/IExtTermController.sol";

/// @notice Data for revealing one or more previously-committed sealed borrower bids.
/// @dev The servicer is recovered from the locker via
///      `IExtTermAuctionBidLocker(bidLocker).termRepoServicer()` so that one BidReveal call
///      carries ids belonging to a single locker. Arrays are length-checked.
///      `uint256[] bidNonces` matches verified on-chain ABI of
///      `IExtTermAuctionBidLocker.revealBids(bytes32[] ids, uint256[] prices, uint256[] nonces)`.
/// @param bidLocker Auction-paired TermAuctionBidLocker proxy
/// @param bidIds Ids of locked bids to reveal
/// @param bidPrices Plaintext rates in 18-dec mantissa, parallel to `bidIds`
/// @param bidNonces Nonces used in the commit hash, parallel to `bidIds`
struct TermFinanceBidRevealFuseEnterData {
    address bidLocker;
    bytes32[] bidIds;
    uint256[] bidPrices;
    uint256[] bidNonces;
}

/// @title TermFinanceBidRevealFuse
/// @author IPOR Labs
/// @notice Reveal previously committed borrower bids during the auction reveal window.
/// @dev Mirror of `TermFinanceOfferRevealFuse` (lender-side) for borrower bids: the BidLocker
///      verifies `keccak256(abi.encode(price, nonce)) == storedHash` per `bidId` and marks
///      the bid as revealed so it can be considered at `completeAuction` time.
///
///      Reveal window semantics (opposite of bid submission): bid SUBMISSION requires `block.timestamp < revealTime`; bid REVEAL requires
///      `block.timestamp >= revealTime`. There is NO on-chain upper bound on reveal — the
///      auction is closed by the AUCTIONEER's `completeAuction` call. The IPOR off-chain
///      keeper bears the responsibility of calling this fuse on time, between `revealTime`
///      and `completeAuction`.
///
///      WithdrawManager check: `_assertWithdrawManagerSet()` runs as the FIRST statement of
///      `enter`. BidReveal does NOT move funds, but the check is included for consistency
///      with `Bid` / `Collateral` / `Repurchase` (the BidReveal step is operationally
///      inseparable from the Bid lifecycle — if WithdrawManager is missing, the Bid that
///      produced these ids should never have been submitted in the first place, and an
///      early revert here surfaces the misconfiguration loudly).
///
///      No `exit()` is exposed — once revealed, a bid is cryptographically committed and
///      cannot be un-revealed. Cancellation pre-reveal is the responsibility of
///      `TermFinanceBidFuse.exit` (`unlockBids`).
///
///      The fuse is STATELESS — it does NOT touch `TermFinancePendingBidsStorageLib`. The
///      pending-bid storage tracks the locked-collateral / amount snapshot that valuation
///      relies on; reveal does not change either, it only flips an on-chain
///      `isRevealed` flag inside the locker.
contract TermFinanceBidRevealFuse is IFuseCommon {
    /// @notice Emitted when one or more borrower bids are successfully revealed.
    /// @param version Address of this fuse instance (event-only version tag).
    /// @param servicer TermRepoServicer paired with the BidLocker.
    /// @param bidLocker TermAuctionBidLocker on which the bids were revealed.
    /// @param bidIds Bid identifiers revealed in this call.
    /// @param bidPrices Plaintext prices revealed (parallel to `bidIds`).
    event TermFinanceBidsRevealed(
        address version,
        address servicer,
        address bidLocker,
        bytes32[] bidIds,
        uint256[] bidPrices
    );

    /// @notice Reverts when the PlasmaVault has no WithdrawManager configured.
    /// @dev Codifies the non-functional requirement: a vault without a WithdrawManager
    ///      could allow withdrawals at any time, bypassing the Term Finance maturity timeline.
    error TermFinanceBidRevealFuseWithdrawManagerRequired();

    /// @notice Reverts when the servicer recovered from `bidLocker.termRepoServicer()` is
    ///         not in the vault's `TERM_FINANCE` market substrate allowlist (TYPE 0x00).
    /// @param servicer The non-allowlisted servicer the locker is paired with.
    error TermFinanceBidRevealFuseUnsupportedMarket(address servicer);

    /// @notice Reverts when `IExtTermController(TERM_CONTROLLER).isTermDeployed(servicer)`
    ///         returns false — i.e. the Term Finance evergreen controller does not recognise
    ///         the resolved `servicer` as a live, deployed `TermRepoServicer`.
    /// @param servicer The servicer that failed the controller deployment check.
    error TermFinanceBidRevealFuseTermNotDeployed(address servicer);

    /// @notice Reverts when the servicer returned by the supplied `bidLocker` does not
    ///         match the IPOR-allowlisted servicer that the alpha intended to operate on.
    /// @dev Resolved by querying `IExtTermAuctionBidLocker(bidLocker).termRepoServicer()`
    ///      and feeding that into the substrate / controller checks. The dedicated error
    ///      surfaces when the recovered servicer is `address(0)` — i.e. a non-locker
    ///      contract was passed and the call returned a zero value rather than reverting.
    /// @param bidLocker The locker passed in calldata that returned a zero servicer.
    error TermFinanceBidRevealFuseBidLockerMismatch(address bidLocker);

    /// @notice Reverts when `controller.isTermDeployed(bidLocker)` returns false.
    /// @param bidLocker The locker that is not a Term-recognised deployment.
    error TermFinanceBidRevealFuseBidLockerNotDeployed(address bidLocker);

    /// @notice Reverts when `bidIds.length == 0`.
    error TermFinanceBidRevealFuseEmptyIds();

    /// @notice Reverts when `bidPrices.length != bidIds.length` or
    ///         `bidNonces.length != bidIds.length`.
    error TermFinanceBidRevealFuseArrayLengthMismatch();

    /// @notice Reverts when `block.timestamp < bidLocker.revealTime()` — i.e. the reveal
    ///         window has not opened yet.
    /// @param nowTs The block timestamp at which the call was attempted.
    /// @param revealTime The locker's `revealTime()` (reveal window opens at or after this).
    error TermFinanceBidRevealFuseRevealWindowNotOpen(uint256 nowTs, uint256 revealTime);

    /// @notice Address of this contract instance, used as the version identifier in event logs.
    address public immutable VERSION;

    /// @notice PlasmaVault market id assigned to Term Finance.
    uint256 public immutable MARKET_ID;

    /// @notice Live Term Finance `TermController` proxy used to verify that the resolved
    ///         servicer is a Term-recognised deployment.
    address public immutable TERM_CONTROLLER;

    /// @notice Initialise immutables.
    /// @dev `marketId_ > 0` and `termController_ != address(0)` are required; market id 0
    ///      is the sentinel for "unconfigured", and a zero controller would silently disable
    ///      the per-call `isTermDeployed` guard.
    ///      The WithdrawManager check is intentionally NOT performed here — see contract
    ///      NatSpec for the rationale (delegatecall context unavailable at deploy time).
    /// @param marketId_ PlasmaVault market id assigned to Term Finance.
    /// @param termController_ Term Finance evergreen `TermController` proxy address.
    constructor(uint256 marketId_, address termController_) {
        if (marketId_ == 0) revert Errors.WrongValue();
        if (termController_ == address(0)) revert Errors.WrongAddress();

        VERSION = address(this);
        MARKET_ID = marketId_;
        TERM_CONTROLLER = termController_;
    }

    /// @notice Reveal one or more previously-committed borrower bids.
    /// @dev Validation order (all-or-nothing; any failure reverts atomically):
    ///      0. `_assertWithdrawManagerSet()` — non-negotiable runtime invariant.
    ///      1. `bidIds.length > 0`.
    ///      2. `bidPrices.length == bidIds.length == bidNonces.length`.
    ///      3. Resolve `servicer = IExtTermAuctionBidLocker(bidLocker).termRepoServicer()`;
    ///         reject `servicer == address(0)` (defensive — surfaces non-locker contracts).
    ///      4. Servicer substrate allowlist (TYPE 0x00 — SERVICER).
    ///      5. `IExtTermController(TERM_CONTROLLER).isTermDeployed(servicer)` — Term Finance
    ///         evergreen controller deployment guard.
    ///      6. `block.timestamp >= bidLocker.revealTime()` (reveal window OPEN). This is the
    ///         opposite direction from `TermFinanceBidFuse.enter` (submission window OPEN
    ///         requires `block.timestamp < revealTime`). There is NO upper bound: the
    ///         auction is closed by the AUCTIONEER's `completeAuction` call, not by the
    ///         locker.
    ///      7. `bidLocker.revealBids(bidIds, bidPrices, bidNonces)`.
    ///      8. Emit `TermFinanceBidsRevealed`.
    /// @param data_ Calldata struct — see `TermFinanceBidRevealFuseEnterData` NatSpec.
    function enter(TermFinanceBidRevealFuseEnterData calldata data_) external {
        _assertWithdrawManagerSet();

        uint256 n = data_.bidIds.length;
        if (n == 0) revert TermFinanceBidRevealFuseEmptyIds();
        if (data_.bidPrices.length != n || data_.bidNonces.length != n) {
            revert TermFinanceBidRevealFuseArrayLengthMismatch();
        }

        IExtTermAuctionBidLocker bidLocker = IExtTermAuctionBidLocker(data_.bidLocker);
        // Anchor the locker to the Term controller before trusting its
        // self-reported servicer. Otherwise a spoofed locker returning a real granted servicer
        // would pass the substrate + isTermDeployed checks below. Reveal moves no funds, but
        // the guard is kept symmetric with BidFuse so a spoofed locker never reaches
        // `revealBids`.
        if (!IExtTermController(TERM_CONTROLLER).isTermDeployed(data_.bidLocker)) {
            revert TermFinanceBidRevealFuseBidLockerNotDeployed(data_.bidLocker);
        }
        address servicer = bidLocker.termRepoServicer();
        if (servicer == address(0)) {
            revert TermFinanceBidRevealFuseBidLockerMismatch(data_.bidLocker);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, servicer)) {
            revert TermFinanceBidRevealFuseUnsupportedMarket(servicer);
        }
        if (!IExtTermController(TERM_CONTROLLER).isTermDeployed(servicer)) {
            revert TermFinanceBidRevealFuseTermNotDeployed(servicer);
        }

        uint256 revealTime = bidLocker.revealTime();
        if (block.timestamp < revealTime) {
            revert TermFinanceBidRevealFuseRevealWindowNotOpen(block.timestamp, revealTime);
        }

        bidLocker.revealBids(data_.bidIds, data_.bidPrices, data_.bidNonces);

        emit TermFinanceBidsRevealed(VERSION, servicer, data_.bidLocker, data_.bidIds, data_.bidPrices);
    }

    /// @notice Reverts unless the vault has a WithdrawManager configured.
    /// @dev See contract NatSpec for rationale. Read directly from the canonical storage
    ///      slot via `PlasmaVaultStorageLib.getWithdrawManager()` — during fuse delegatecall
    ///      the slot is read from PlasmaVault storage (the intended context). Mirror of
    ///      `BurnRequestFeeFuse._assertWithdrawManagerSet`.
    function _assertWithdrawManagerSet() private view {
        if (PlasmaVaultStorageLib.getWithdrawManager().manager == address(0)) {
            revert TermFinanceBidRevealFuseWithdrawManagerRequired();
        }
    }
}

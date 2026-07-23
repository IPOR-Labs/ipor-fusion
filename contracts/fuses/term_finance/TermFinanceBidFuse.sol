// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Errors} from "../../libraries/errors/Errors.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "../../libraries/PlasmaVaultStorageLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IExtTermAuctionBidLocker} from "./ext/IExtTermAuctionBidLocker.sol";
import {IExtTermController} from "./ext/IExtTermController.sol";
import {IExtTermRepoServicer} from "./ext/IExtTermRepoServicer.sol";
import {TermFinancePendingBidsStorageLib} from "./lib/TermFinancePendingBidsStorageLib.sol";
import {TermFinanceSubstrateLib} from "./lib/TermFinanceSubstrateLib.sol";

/// @notice Data for locking (or editing) a sealed-bid borrower bid in a Term Finance auction.
/// @param servicer Substrate key — TermRepoServicer proxy of the target Term Repo
/// @param bidLocker Auction-paired TermAuctionBidLocker proxy
/// @param collateralManager TermRepoCollateralManager proxy of the target Term Repo; validated
///        against `IExtTermRepoServicer(servicer).termRepoCollateralManager()`
///        (impersonation guard)
/// @param amount Purchase-token raw units to borrow
/// @param bidPriceHash keccak256(abi.encode(price, nonce)) — commit-phase rate hash
/// @param existingBidId 0x0 for a fresh bid; non-zero to edit an existing one (edit-flow)
/// @param collateralTokens Parallel to `collateralAmounts`; per-token collateral allowlist
///        enforced via `TermFinanceSubstrateLib.collateralPairKey(servicer, token)`
/// @param collateralAmounts Parallel to `collateralTokens`; raw token units to lock per token
struct TermFinanceBidFuseEnterData {
    address servicer;
    address bidLocker;
    address collateralManager;
    uint256 amount;
    bytes32 bidPriceHash;
    bytes32 existingBidId;
    address[] collateralTokens;
    uint256[] collateralAmounts;
}

/// @notice Data for unlocking (pre-reveal cancel) one or more committed bids.
/// @param servicer Substrate key — TermRepoServicer proxy of the target Term Repo
/// @param bidLocker Auction-paired TermAuctionBidLocker proxy
/// @param bidIds Ids of locked bids to cancel
struct TermFinanceBidFuseExitData {
    address servicer;
    address bidLocker;
    bytes32[] bidIds;
}

/// @title TermFinanceBidFuse
/// @author IPOR Labs
/// @notice Submit and cancel sealed-bid borrower bids in Term Finance auctions.
/// @dev Mirror of `TermFinanceOfferFuse` for the borrower side. Substrates are typed via
///      `TermFinanceSubstrateLib`: servicer substrates use TYPE 0x00 (SERVICER, address-encoded
///      and backward-compatible with the lender-side substrates); collateral substrates are
///      composite `(servicer, collateralToken)` keys under TYPE 0x01 (COLLATERAL_TOKEN).
///
///      Approval flow: the per-token `forceApprove(termRepoLocker, amount)` calls and the
///      `lockBids(...)` call happen inside the same `enter()` invocation. The approval target
///      is the per-Term `TermRepoLocker` (resolved via `IExtTermRepoServicer(servicer).termRepoLocker()`),
///      NOT the `TermAuctionBidLocker` itself — `lockBids` pulls tokens through the
///      `TermRepoLocker.transferTokenFromWallet(borrower, ...)` pathway.
///
///      Submission window: `block.timestamp < bidLocker.revealTime()`.
///      `revealTime` is the load-bearing cutoff — at-or-after `revealTime`, only `revealBids()`
///      is accepted. `auctionEndTime` belongs to the clearing phase that runs AFTER reveal and
///      is NOT the bid-submission cutoff.
///
///      Storage-write ordering:
///        - `enter` writes pending-bid storage AFTER `lockBids` returns (the locker is what
///          assigns the `bidId`).
///        - `exit` clears pending-bid storage BEFORE the external `unlockBids` interaction
///          (strict CEI, mirror of `OfferFuse.exit`).
///
///      Edit-flow (`existingBidId != 0x0`): a single bid id is replaced in place. The fuse
///      first removes the stale storage entry, then submits with the same id (the locker
///      reuses ids per the verified ABI), and finally re-inserts the entry — which
///      `TermFinancePendingBidsStorageLib.addPendingBid` resolves as an in-place refresh
///      (storage length does not change). The edit path is exempt from the
///      `MAX_PENDING_BIDS_PER_SERVICER` cap check (no length increase).
///
///      Anti-griefing cap: BEFORE the approval loop / `lockBids` on the non-edit path,
///      `enter()` enforces
///      `TermFinancePendingBidsStorageLib.length(servicer) + 1 <= MAX_PENDING_BIDS_PER_SERVICER`
///      to prevent a buggy or malicious caller from OOG-bombing
///      `_pendingBidsValueWadForServicer` in `balanceOf()`. The cap mirrors the
///      upstream BidLocker `MAX_BID_COUNT = 150`.
///
///      WithdrawManager check: `_assertWithdrawManagerSet()` runs as the FIRST statement of
///      BOTH `enter()` and `exit()`. The check is NOT in the constructor because the
///      delegatecall context is not available at deploy time (the constructor runs in the
///      deployer's storage context, which would read empty storage and unconditionally
///      revert). Mirror of `BurnRequestFeeFuse.enter()`. Codifies the non-negotiable
///      invariant that a vault without a WithdrawManager could allow withdrawals at any
///      time, bypassing the Term Finance maturity timeline and underwatering the vault.
contract TermFinanceBidFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    /// @notice Emitted when a sealed-bid borrower bid is successfully locked in a Term Finance auction.
    /// @param version Address of this fuse instance (event-only version tag).
    /// @param servicer TermRepoServicer substrate associated with the bid.
    /// @param bidLocker TermAuctionBidLocker that recorded the bid.
    /// @param bidId Bid identifier assigned by the locker (fresh or reused on edit-flow).
    /// @param amount Purchase-token raw units requested.
    /// @param bidPriceHash Commit-phase rate hash.
    /// @param collateralTokens Collateral ERC20s locked alongside the bid (parallel to `collateralAmounts`).
    /// @param collateralAmounts Collateral raw units locked alongside the bid (parallel to `collateralTokens`).
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

    /// @notice Emitted on a pre-reveal cancel (`exit`).
    /// @param version Address of this fuse instance (event-only version tag).
    /// @param servicer TermRepoServicer substrate associated with the bids.
    /// @param bidLocker TermAuctionBidLocker that recorded the bids.
    /// @param bidIds Bid identifiers cancelled in this call.
    event TermFinanceBidUnlocked(address version, address servicer, address bidLocker, bytes32[] bidIds);

    /// @notice Reverts when the PlasmaVault has no WithdrawManager configured.
    /// @dev Codifies the non-functional requirement: a vault without a WithdrawManager
    ///      could allow withdrawals at any time, bypassing the Term Finance maturity timeline.
    error TermFinanceBidFuseWithdrawManagerRequired();

    /// @notice Reverts when `servicer` is not in the vault's `TERM_FINANCE` market substrate
    ///         allowlist (as a `SERVICER`-typed substrate).
    /// @param servicer The non-allowlisted servicer that was passed in calldata.
    error TermFinanceBidFuseUnsupportedMarket(address servicer);

    /// @notice Reverts when `controller.isTermDeployed(servicer)` returns false.
    /// @param servicer The servicer address that failed the controller deployment check.
    error TermFinanceBidFuseTermNotDeployed(address servicer);

    /// @notice Reverts when `IExtTermAuctionBidLocker(bidLocker).termRepoServicer() != servicer`
    ///         (impersonation guard).
    /// @param servicer The servicer that was claimed via calldata.
    /// @param expected The servicer the locker actually pairs with.
    /// @param actual The servicer supplied via calldata (== `expected` would not revert).
    error TermFinanceBidFuseBidLockerMismatch(address servicer, address expected, address actual);

    /// @notice Reverts when `controller.isTermDeployed(bidLocker)` returns false.
    /// @param bidLocker The locker that is not a Term-recognised deployment.
    error TermFinanceBidFuseBidLockerNotDeployed(address bidLocker);

    /// @notice Reverts when `IExtTermRepoServicer(servicer).termRepoCollateralManager()` does
    ///         not match the `collateralManager` supplied in calldata (impersonation guard).
    /// @param servicer The servicer whose pairing was checked.
    /// @param expected The collateralManager returned by the servicer.
    /// @param actual The collateralManager supplied via calldata.
    error TermFinanceBidFuseServicerCollateralManagerMismatch(
        address servicer,
        address expected,
        address actual
    );

    /// @notice Reverts when `enter` is called with `amount == 0`.
    error TermFinanceBidFuseZeroAmount();

    /// @notice Reverts when `lockBids` returns an unexpected number of ids (expected exactly 1).
    /// @param returnedBidsCount The number of ids returned by the locker.
    error TermFinanceBidFuseUnexpectedLockResult(uint256 returnedBidsCount);

    /// @notice Reverts when a collateral token is not allowlisted as a `(servicer, token)` pair.
    /// @param servicer The servicer paired with the offending token.
    /// @param token The collateral token that failed the substrate allowlist check.
    error TermFinanceBidFuseUnsupportedCollateral(address servicer, address token);

    /// @notice Reverts when `collateralTokens.length != collateralAmounts.length`.
    error TermFinanceBidFuseArrayLengthMismatch();

    /// @notice Reverts when `enter` receives duplicate collateral tokens.
    /// @dev A duplicate would let the per-token approval loop overwrite earlier
    ///      approvals, while pending-bid storage records the summed amount — net result
    ///      is NAV over-reporting against the actual locker balance. O(n^2) check is fine
    ///      since n is bounded (observed <= 3 in practice, hard cap via the pending-bid cap).
    /// @param token Duplicated collateral token.
    error TermFinanceBidFuseDuplicateCollateralToken(address token);

    /// @notice Reverts when `block.timestamp >= bidLocker.revealTime()` (the submission window
    ///         is closed and only `revealBids()` is accepted).
    /// @param nowTs Current `block.timestamp`.
    /// @param revealTime The reveal-window start (= the submission-window cutoff).
    error TermFinanceBidFuseSubmissionWindowClosed(uint256 nowTs, uint256 revealTime);

    /// @notice Reverts when a fresh-insert enter would push the pending-bid count for
    ///         `servicer` over the anti-griefing cap. Checked BEFORE the approval loop /
    ///         `lockBids` so cap-breach has no side effects.
    /// @param servicer The servicer whose pending-bid count was breached.
    /// @param count The would-be length (`current + 1`, always > MAX_PENDING_BIDS_PER_SERVICER
    ///        on revert).
    error TermFinanceBidFuseTooManyPendingBids(address servicer, uint256 count);

    /// @notice Address of this contract instance, used as the version identifier in event logs.
    address public immutable VERSION;

    /// @notice PlasmaVault market id assigned to Term Finance.
    uint256 public immutable MARKET_ID;

    /// @notice Live Term Finance `TermController` proxy used to verify that each servicer
    ///         passed in calldata is a Term-recognised deployment.
    address public immutable TERM_CONTROLLER;

    /// @notice Initialise immutables.
    /// @dev `marketId_ > 0` and `termController_ != address(0)` are required; market id 0 is
    ///      the sentinel for "unconfigured", and a zero controller would silently disable the
    ///      per-call `isTermDeployed` guard.
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

    /// @notice Lock a single sealed-bid borrower bid (or replace an existing one) during the
    ///         submission window.
    /// @dev Validation order (all-or-nothing; any failure reverts atomically):
    ///      0. `_assertWithdrawManagerSet()` — non-negotiable runtime invariant.
    ///      1. Servicer substrate allowlist (typed `SERVICER`) + `isTermDeployed`.
    ///      2. `bidLocker.termRepoServicer() == data_.servicer` (impersonation guard).
    ///      3. `block.timestamp < bidLocker.revealTime()` (submission window).
    ///      4. `data_.amount > 0`.
    ///      5. `collateralTokens.length == collateralAmounts.length`.
    ///      6. Per-token `(servicer, token)` substrate allowlist (typed `COLLATERAL_TOKEN`).
    ///      7. `servicer.termRepoCollateralManager() == data_.collateralManager` (impersonation guard).
    ///      8. Non-edit-flow only: enforce the pending-bid cap BEFORE
    ///         any approval or external call so a cap-breach reverts cheaply with no side
    ///         effects on the vault or the locker.
    ///      9. Edit-flow: drop the stale pending entry BEFORE `lockBids` reuses the id.
    ///     10. `forceApprove(termRepoLocker, amount)` for the purchase token AND each collateral token.
    ///     11. Build `TermAuctionBidSubmission[]` in the verified on-chain field order
    ///         (id, bidder, bidPriceHash, amount, collateralAmounts, purchaseToken, collateralTokens)
    ///         and call `lockBids`.
    ///     12. Defensive `forceApprove(termRepoLocker, 0)` cleanup for purchase token + each collateral
    ///         token (mirror of `OfferFuse.enter`; safeguards against any future locker impl that
    ///         partial-pulls).
    ///     13. Assert `bidIds.length == 1` (else revert `UnexpectedLockResult`).
    ///     14. Write the entry to `TermFinancePendingBidsStorageLib` (asymmetric vs `exit` — the
    ///         locker is what assigns the id).
    ///     15. Emit `TermFinanceBidLocked`.
    /// @param data_ Calldata struct — see `TermFinanceBidFuseEnterData` NatSpec.
    function enter(TermFinanceBidFuseEnterData calldata data_) external {
        _assertWithdrawManagerSet();
        _assertServicerAllowed(data_.servicer);
        _assertBidLockerPaired(data_.bidLocker, data_.servicer);
        _assertSubmissionWindowOpen(data_.bidLocker);

        if (data_.amount == 0) revert TermFinanceBidFuseZeroAmount();

        uint256 collateralCount = data_.collateralTokens.length;
        if (collateralCount != data_.collateralAmounts.length) {
            revert TermFinanceBidFuseArrayLengthMismatch();
        }

        _assertCollateralPairsAllowed(data_.servicer, data_.collateralTokens);
        _assertServicerCollateralManagerPaired(data_.servicer, data_.collateralManager);

        // Duplicate collateral tokens would let the per-token approval loop
        // overwrite earlier approvals (final approval = LAST amount, not the sum) while
        // pending-bid storage records the SUMMED amount — NAV would over-report against
        // the actual locker balance. O(n^2) is acceptable: n is bounded (observed <= 3
        // in practice; hard cap via the pending-bid cap).
        for (uint256 i; i < collateralCount; ++i) {
            for (uint256 j = i + 1; j < collateralCount; ++j) {
                if (data_.collateralTokens[i] == data_.collateralTokens[j]) {
                    revert TermFinanceBidFuseDuplicateCollateralToken(data_.collateralTokens[i]);
                }
            }
        }

        _consumeExistingBidAndEnforceCap(data_.servicer, data_.existingBidId);

        address termRepoLocker = IExtTermRepoServicer(data_.servicer).termRepoLocker();
        address purchaseToken = IExtTermRepoServicer(data_.servicer).purchaseToken();

        // Approval loop AND lockBids call MUST stay in the same enter() invocation — Solidity
        // revert atomicity is what cleanly undoes per-token approvals if lockBids reverts
        // mid-execution.
        //
        // A BORROWER bid locks COLLATERAL and receives the loan at clearing — it
        // never transfers the purchase (loan) token. Verified against the live BidLocker impl
        // 0xEC2125566ee98761d0605E42B0c3b2adeB051007 (`_lock`): the purchase token is only
        // checked for equality (`purchaseToken == bidSubmission.purchaseToken`) and the only
        // pull is `auctionLockCollateral` on the collateral tokens. The previous
        // `forceApprove(termRepoLocker, amount)` on the purchase token (copied from
        // OfferFuse, where the lender legitimately supplies it) was a spurious live allowance;
        // it is removed so only collateral is ever approved.
        for (uint256 i; i < collateralCount; ++i) {
            ERC20(data_.collateralTokens[i]).forceApprove(termRepoLocker, data_.collateralAmounts[i]);
        }

        IExtTermAuctionBidLocker.TermAuctionBidSubmission[]
            memory submissions = new IExtTermAuctionBidLocker.TermAuctionBidSubmission[](1);
        // Verified on-chain field order: id, bidder, bidPriceHash, amount,
        // collateralAmounts, purchaseToken, collateralTokens. Do NOT reorder — verified
        // against impl 0xEC2125566ee98761d0605E42B0c3b2adeB051007 (v0.9.0) on Ethereum
        // mainnet on 2026-05-15.
        submissions[0] = IExtTermAuctionBidLocker.TermAuctionBidSubmission({
            id: data_.existingBidId,
            bidder: address(this),
            bidPriceHash: data_.bidPriceHash,
            amount: data_.amount,
            collateralAmounts: data_.collateralAmounts,
            purchaseToken: purchaseToken,
            collateralTokens: data_.collateralTokens
        });

        bytes32[] memory bidIds = IExtTermAuctionBidLocker(data_.bidLocker).lockBids(submissions);

        // Defensive approval cleanup — lockBids is expected to consume exactly the locked
        // collateral, but the reset guards against any future impl that partial-pulls. Only
        // collateral is approved (see the note above), so only collateral is reset.
        for (uint256 i; i < collateralCount; ++i) {
            ERC20(data_.collateralTokens[i]).forceApprove(termRepoLocker, 0);
        }

        // Defensive guard against a buggy/malicious locker proxy returning [] (OOB revert
        // with an obscure selector) or >1 entries (orphaned ids → locked funds, no NAV, no
        // tracking). Submissions array length is exactly 1 above, so any other return is
        // a contract bug.
        if (bidIds.length != 1) revert TermFinanceBidFuseUnexpectedLockResult(bidIds.length);

        bytes32 bidId = bidIds[0];

        TermFinancePendingBidsStorageLib.addPendingBid(
            data_.servicer,
            data_.bidLocker,
            bidId,
            data_.amount,
            data_.collateralTokens,
            data_.collateralAmounts
        );

        emit TermFinanceBidLocked(
            VERSION,
            data_.servicer,
            data_.bidLocker,
            bidId,
            data_.amount,
            data_.bidPriceHash,
            data_.collateralTokens,
            data_.collateralAmounts
        );
    }

    /// @notice Cancel pre-reveal — unlock a list of committed bids, returning collateral and
    ///         purchase tokens from `TermRepoLocker` back to the PlasmaVault.
    /// @dev Strict CEI: pending-bid storage is cleared BEFORE the external `unlockBids`
    ///      interaction. The asymmetric ordering vs `enter` (where storage must be written
    ///      AFTER `lockBids` because the locker is what assigns the `bidId`) is structural
    ///      and acceptable; here the ids are known up-front so storage goes first.
    ///      Reentrancy is also gated by PlasmaVault's `nonReentrant`, but defense-in-depth
    ///      requires effects-before-interactions.
    /// @param data_ Calldata struct — see `TermFinanceBidFuseExitData` NatSpec.
    function exit(TermFinanceBidFuseExitData calldata data_) external {
        _assertWithdrawManagerSet();
        _assertServicerAllowed(data_.servicer);
        _assertBidLockerPaired(data_.bidLocker, data_.servicer);

        uint256 n = data_.bidIds.length;
        for (uint256 i; i < n; ++i) {
            TermFinancePendingBidsStorageLib.removePendingBidIfExists(data_.servicer, data_.bidIds[i]);
        }

        IExtTermAuctionBidLocker(data_.bidLocker).unlockBids(data_.bidIds);

        emit TermFinanceBidUnlocked(VERSION, data_.servicer, data_.bidLocker, data_.bidIds);
    }

    /// @notice Drop the stale pending-bid entry on the edit-flow path and enforce the
    ///         `MAX_PENDING_BIDS_PER_SERVICER` cap when storage would actually grow.
    /// @dev The cap-check MUST run on any path that grows the pending-bid
    ///      tally. The edit-flow (`existingBidId != 0`) is exempt ONLY when the entry was
    ///      actually present in storage — `removePendingBidIfExists` now returns `bool` so
    ///      we can distinguish a true in-place refresh (length unchanged) from a caller
    ///      supplying a fake / unknown `existingBidId`. Without this gate an attacker who
    ///      controls Alpha (governance-restricted) could pass arbitrary non-zero ids,
    ///      pairing with a locker proxy that accepts caller-supplied ids, to grow the
    ///      pending-bid array past the cap and OOG-bomb every subsequent `balanceOf`.
    ///      Extracted into a separate function to keep `enter` under the 16-slot stack
    ///      limit imposed by Solidity without `viaIR`.
    /// @param servicer_ Servicer substrate from the calldata struct.
    /// @param existingBidId_ Existing bid id from the calldata struct (`0x0` for fresh).
    function _consumeExistingBidAndEnforceCap(address servicer_, bytes32 existingBidId_) private {
        bool storageGrows;
        if (existingBidId_ == bytes32(0)) {
            storageGrows = true;
        } else {
            bool removed = TermFinancePendingBidsStorageLib.removePendingBidIfExists(servicer_, existingBidId_);
            storageGrows = !removed;
        }
        if (storageGrows) {
            uint256 nextLength = TermFinancePendingBidsStorageLib.length(servicer_) + 1;
            if (nextLength > TermFinancePendingBidsStorageLib.MAX_PENDING_BIDS_PER_SERVICER) {
                revert TermFinanceBidFuseTooManyPendingBids(servicer_, nextLength);
            }
        }
    }

    /// @notice Reverts unless the vault has a WithdrawManager configured.
    /// @dev See contract NatSpec for rationale. Read directly from the canonical storage
    ///      slot via `PlasmaVaultStorageLib.getWithdrawManager()` — during fuse delegatecall
    ///      the slot is read from PlasmaVault storage (the intended context).
    function _assertWithdrawManagerSet() private view {
        if (PlasmaVaultStorageLib.getWithdrawManager().manager == address(0)) {
            revert TermFinanceBidFuseWithdrawManagerRequired();
        }
    }

    /// @notice Combined substrate-allowlist + controller-isTermDeployed guard.
    /// @param servicer_ Substrate to check.
    function _assertServicerAllowed(address servicer_) private view {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, servicer_)) {
            revert TermFinanceBidFuseUnsupportedMarket(servicer_);
        }
        if (!IExtTermController(TERM_CONTROLLER).isTermDeployed(servicer_)) {
            revert TermFinanceBidFuseTermNotDeployed(servicer_);
        }
    }

    /// @notice Confirms the bidLocker passed in calldata is the one paired with `servicer_`
    ///         (impersonation guard against a contract exposing the same selectors).
    /// @dev The mismatch error reports `(servicer_, expectedServicerFromLocker, claimedServicer)`
    ///      where `claimedServicer == servicer_`. The triple is kept so downstream tooling can
    ///      distinguish "locker paired with a different servicer" from "calldata-claimed servicer
    ///      differs from substrate". For this fuse the two collapse, so `actual == servicer_`.
    /// @param bidLocker_ Locker address passed in calldata.
    /// @param servicer_ Substrate key.
    function _assertBidLockerPaired(address bidLocker_, address servicer_) private view {
        // The `termRepoServicer() == servicer_` pairing alone is spoofable — a
        // malicious alpha can deploy a contract whose `termRepoServicer()` returns the real
        // granted servicer, pass it as `bidLocker`, have `lockBids` move no collateral, and
        // record a phantom pending bid that inflates NAV (its stored collateral is double-
        // counted against the vault's retained balance). The servicer is anchored to
        // governance via the substrate allowlist + `isTermDeployed`, but the locker is NOT
        // derivable from the servicer (no getter), so we anchor it the same way: require the
        // controller to recognise the locker as a genuine Term deployment. Verified on
        // Ethereum mainnet 2026-06-10 that `isTermDeployed` returns true for live
        // `TermAuctionBidLocker` proxies.
        if (!IExtTermController(TERM_CONTROLLER).isTermDeployed(bidLocker_)) {
            revert TermFinanceBidFuseBidLockerNotDeployed(bidLocker_);
        }
        address paired = IExtTermAuctionBidLocker(bidLocker_).termRepoServicer();
        if (paired != servicer_) {
            revert TermFinanceBidFuseBidLockerMismatch(servicer_, paired, servicer_);
        }
    }

    /// @notice Reverts unless `block.timestamp < bidLocker.revealTime()`.
    /// @dev The submission window ends at `revealTime`; after `revealTime`, only `revealBids()`
    ///      is accepted by the locker. `auctionEndTime` is reserved for the clearing phase and
    ///      is NOT the bid-submission cutoff.
    /// @param bidLocker_ Locker whose `revealTime()` defines the cutoff.
    function _assertSubmissionWindowOpen(address bidLocker_) private view {
        uint256 revealTime = IExtTermAuctionBidLocker(bidLocker_).revealTime();
        if (block.timestamp >= revealTime) {
            revert TermFinanceBidFuseSubmissionWindowClosed(block.timestamp, revealTime);
        }
    }

    /// @notice Reverts unless every `(servicer_, collateralTokens_[i])` pair is allowlisted as
    ///         a `COLLATERAL_TOKEN`-typed substrate on the vault.
    /// @param servicer_ TermRepoServicer proxy address.
    /// @param collateralTokens_ Per-bid collateral tokens.
    function _assertCollateralPairsAllowed(address servicer_, address[] calldata collateralTokens_) private view {
        uint256 n = collateralTokens_.length;
        for (uint256 i; i < n; ++i) {
            bytes32 pairKey = TermFinanceSubstrateLib.collateralPairKey(servicer_, collateralTokens_[i]);
            if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, pairKey)) {
                revert TermFinanceBidFuseUnsupportedCollateral(servicer_, collateralTokens_[i]);
            }
        }
    }

    /// @notice Reverts unless `servicer_.termRepoCollateralManager()` matches the
    ///         `collateralManager_` supplied in calldata (impersonation guard).
    /// @dev Without this check, an alpha could pass a forged `collateralManager` exposing the
    ///      same selectors and divert collateral approvals to it.
    /// @param servicer_ TermRepoServicer proxy address.
    /// @param collateralManager_ TermRepoCollateralManager address from calldata.
    function _assertServicerCollateralManagerPaired(address servicer_, address collateralManager_) private view {
        address expected = IExtTermRepoServicer(servicer_).termRepoCollateralManager();
        if (expected != collateralManager_) {
            revert TermFinanceBidFuseServicerCollateralManagerMismatch(
                servicer_,
                expected,
                collateralManager_
            );
        }
    }
}

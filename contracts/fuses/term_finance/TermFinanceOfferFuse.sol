// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Errors} from "../../libraries/errors/Errors.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "../../libraries/PlasmaVaultStorageLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IExtTermAuctionOfferLocker} from "./ext/IExtTermAuctionOfferLocker.sol";
import {IExtTermController} from "./ext/IExtTermController.sol";
import {IExtTermRepoServicer} from "./ext/IExtTermRepoServicer.sol";
import {TermFinancePendingOffersStorageLib} from "./lib/TermFinancePendingOffersStorageLib.sol";

/// @notice Data for locking (committing) a sealed-bid lender offer.
/// @param servicer Substrate key — TermRepoServicer proxy of the target Term Repo
/// @param offerLocker Auction-paired TermAuctionOfferLocker proxy
/// @param amount Purchase-token raw units to lend
/// @param offerPriceHash keccak256(abi.encode(price, nonce)) — commit-phase rate hash
/// @param existingOfferId 0x0 for a fresh offer; non-zero to edit an existing one
struct TermFinanceOfferFuseEnterData {
    address servicer;
    address offerLocker;
    uint256 amount;
    bytes32 offerPriceHash;
    bytes32 existingOfferId;
}

/// @notice Data for unlocking (pre-reveal cancel) one or more committed offers.
struct TermFinanceOfferFuseExitData {
    address servicer;
    address offerLocker;
    bytes32[] offerIds;
}

/// @title TermFinanceOfferFuse
/// @author IPOR Labs
/// @notice Submit and cancel sealed-bid lender offers in Term Finance auctions.
/// @dev Substrates are TermRepoServicer proxy addresses. Approval target is the per-Term
///      `TermRepoLocker` (resolved via `IExtTermRepoServicer(servicer).termRepoLocker()`),
///      NOT the OfferLocker - this is a load-bearing correction from the upstream call
///      chain.
///
///      Edit-flow (`existingOfferId != 0x0`): a single offer id is replaced in place. The
///      fuse first removes the stale storage entry, then submits with the same id, and finally
///      re-inserts the entry which `addPendingOffer` resolves as an in-place refresh (storage
///      length does not change). The edit path is exempt from the cap ONLY when the entry was
///      actually tracked (the `bool removed` signal); a fake `existingOfferId` is treated as a
///      fresh insert and must respect the cap.
///
///      Anti-griefing cap: BEFORE the `forceApprove` / `lockOffers` call on any storage-growing
///      path, `enter()` enforces
///      `TermFinancePendingOffersStorageLib.length(servicer) + 1 <= MAX_PENDING_OFFERS_PER_SERVICER`
///      to prevent a buggy or malicious caller from OOG-bombing `_sumLivePendingOffers` in
///      `balanceOf()`. The cap is intentionally 500 — HIGHER than the bid side's
///      150 and NOT the upstream per-auction `MAX_OFFER_COUNT = 150` — because this storage
///      accumulates across auction cycles whereas the upstream counter resets each cycle. See
///      the `MAX_PENDING_OFFERS_PER_SERVICER` NatSpec for the sizing rationale.
contract TermFinanceOfferFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    /// @notice Emitted when a sealed-bid offer is successfully locked in a Term Finance auction.
    event TermFinanceOfferLocked(
        address version, address servicer, address offerLocker, bytes32 offerId, uint256 amount, bytes32 offerPriceHash
    );

    /// @notice Emitted on a pre-reveal cancel (`exit`).
    event TermFinanceOfferUnlocked(address version, address servicer, address offerLocker, bytes32[] offerIds);

    /// @notice Reverts when the PlasmaVault has no WithdrawManager configured.
    /// @dev Codifies the non-functional requirement: a vault without a WithdrawManager
    ///      could allow LP withdrawals at any time, bypassing the Term Finance maturity timeline.
    ///      Mirror of `TermFinanceBidFuse.TermFinanceBidFuseWithdrawManagerRequired`.
    error TermFinanceOfferFuseWithdrawManagerRequired();

    /// @notice Reverts when `servicer` is not in the vault's `TERM_FINANCE` market substrate allowlist.
    error TermFinanceOfferFuseUnsupportedMarket(address servicer);
    /// @notice Reverts when `controller.isTermDeployed(servicer)` returns false.
    error TermFinanceOfferFuseTermNotDeployed(address servicer);
    /// @notice Reverts when the supplied offerLocker is paired with a different servicer than expected.
    /// @param expected Servicer the locker is actually paired with.
    /// @param actual Servicer supplied by the caller.
    error TermFinanceOfferFuseOfferLockerMismatch(address expected, address actual);
    /// @notice Reverts when `controller.isTermDeployed(offerLocker)` returns false.
    /// @param offerLocker The locker that is not a Term-recognised deployment.
    error TermFinanceOfferFuseOfferLockerNotDeployed(address offerLocker);
    /// @notice Reverts when `enter` is called with `amount == 0`.
    error TermFinanceOfferFuseZeroAmount();
    /// @notice Reverts when `lockOffers` returns an unexpected number of ids (expected exactly 1).
    error TermFinanceOfferFuseUnexpectedLockResult(uint256 returnedLength);

    /// @notice Reverts when a storage-growing `enter` would push the pending-offer count for
    ///         `servicer` over the anti-griefing cap. Checked BEFORE the `forceApprove` /
    ///         `lockOffers` call so a cap-breach has no approval side effects and
    ///         does not invoke the external locker.
    /// @param servicer The servicer whose pending-offer count was breached.
    /// @param count The would-be length (`current + 1`, always > MAX_PENDING_OFFERS_PER_SERVICER
    ///        on revert).
    error TermFinanceOfferFuseTooManyPendingOffers(address servicer, uint256 count);

    /// @notice Address of this contract instance, used as the version identifier in event logs.
    address public immutable VERSION;
    /// @notice PlasmaVault market id assigned to Term Finance.
    uint256 public immutable MARKET_ID;
    /// @notice Live Term Finance `TermController` proxy.
    address public immutable TERM_CONTROLLER;

    /// @notice Initialise immutables; marketId > 0 and controller != 0 required.
    /// @param marketId_ PlasmaVault market id
    /// @param termController_ Term Finance evergreen controller proxy
    constructor(uint256 marketId_, address termController_) {
        if (marketId_ == 0) revert Errors.WrongValue();
        if (termController_ == address(0)) revert Errors.WrongAddress();

        VERSION = address(this);
        MARKET_ID = marketId_;
        TERM_CONTROLLER = termController_;
    }

    /// @notice Lock a single sealed-bid offer (or replace an existing one) during the
    ///         submission window.
    function enter(TermFinanceOfferFuseEnterData calldata data_) external {
        _assertWithdrawManagerSet();
        _assertServicerAllowed(data_.servicer);
        _assertOfferLockerPaired(data_.offerLocker, data_.servicer);
        if (data_.amount == 0) revert TermFinanceOfferFuseZeroAmount();

        // Drop the stale entry on the edit-flow path and enforce the
        // pending-offer cap on any path that actually grows storage. BEFORE forceApprove /
        // lockOffers so a cap-breach reverts cheaply with no side effects.
        _consumeExistingOfferAndEnforceCap(data_.servicer, data_.existingOfferId);

        address termRepoLocker = IExtTermRepoServicer(data_.servicer).termRepoLocker();
        address purchaseToken = IExtTermRepoServicer(data_.servicer).purchaseToken();

        ERC20(purchaseToken).forceApprove(termRepoLocker, data_.amount);

        IExtTermAuctionOfferLocker.TermAuctionOfferSubmission[] memory submissions =
            new IExtTermAuctionOfferLocker.TermAuctionOfferSubmission[](1);
        submissions[0] = IExtTermAuctionOfferLocker.TermAuctionOfferSubmission({
            id: data_.existingOfferId,
            offeror: address(this),
            offerPriceHash: data_.offerPriceHash,
            amount: data_.amount,
            purchaseToken: purchaseToken
        });

        bytes32[] memory ids = IExtTermAuctionOfferLocker(data_.offerLocker).lockOffers(submissions);

        ERC20(purchaseToken).forceApprove(termRepoLocker, 0);

        // Defensive guard against a buggy/malicious locker proxy returning [] (OOB revert with
        // an obscure selector) or >1 entries (orphaned ids → locked funds, no NAV, no tracking).
        // Submissions array length is exactly 1 above, so any other return is a contract bug.
        if (ids.length != 1) revert TermFinanceOfferFuseUnexpectedLockResult(ids.length);

        bytes32 offerId = ids[0];
        TermFinancePendingOffersStorageLib.addPendingOffer(data_.servicer, data_.offerLocker, offerId, data_.amount);

        emit TermFinanceOfferLocked(
            VERSION, data_.servicer, data_.offerLocker, offerId, data_.amount, data_.offerPriceHash
        );
    }

    /// @notice Drop the stale pending-offer entry on the edit-flow path and enforce the
    ///         `MAX_PENDING_OFFERS_PER_SERVICER` cap when storage would actually grow.
    /// @dev The cap-check MUST run on any path that grows the pending-offer
    ///      tally. The edit-flow (`existingOfferId != 0`) is exempt ONLY when the entry was
    ///      actually present in storage — `removePendingOfferIfExists` returns `bool` so we
    ///      can distinguish a true in-place refresh (length unchanged) from a caller supplying
    ///      a fake / unknown `existingOfferId`. Without this gate an Alpha (governance-
    ///      restricted) could pass arbitrary non-zero ids, pairing with a locker proxy that
    ///      accepts caller-supplied ids, to grow the pending-offer array past the cap and
    ///      OOG-bomb every subsequent `balanceOf`. Mirror of
    ///      `TermFinanceBidFuse._consumeExistingBidAndEnforceCap`.
    /// @param servicer_ Servicer substrate from the calldata struct.
    /// @param existingOfferId_ Existing offer id from the calldata struct (`0x0` for fresh).
    function _consumeExistingOfferAndEnforceCap(address servicer_, bytes32 existingOfferId_) private {
        bool storageGrows;
        if (existingOfferId_ == bytes32(0)) {
            storageGrows = true;
        } else {
            bool removed = TermFinancePendingOffersStorageLib.removePendingOfferIfExists(servicer_, existingOfferId_);
            storageGrows = !removed;
        }
        if (storageGrows) {
            uint256 nextLength = TermFinancePendingOffersStorageLib.length(servicer_) + 1;
            if (nextLength > TermFinancePendingOffersStorageLib.MAX_PENDING_OFFERS_PER_SERVICER) {
                revert TermFinanceOfferFuseTooManyPendingOffers(servicer_, nextLength);
            }
        }
    }

    /// @notice Cancel pre-reveal — unlock a list of committed offers, returning purchase
    ///         tokens from `TermRepoLocker` back to the PlasmaVault.
    /// @dev Strict CEI: pending-offer storage is cleared BEFORE the external `unlockOffers`
    ///      interaction. The asymmetric ordering vs `enter` (where storage must be written
    ///      AFTER `lockOffers` because the locker is what assigns the `offerId`) is
    ///      structural and acceptable; here we have the ids up-front so storage goes first.
    ///      Reentrancy is also gated by PlasmaVault's `nonReentrant`, but defense-in-depth
    ///      requires effects-before-interactions.
    function exit(TermFinanceOfferFuseExitData calldata data_) external {
        _assertWithdrawManagerSet();
        _assertServicerAllowed(data_.servicer);
        _assertOfferLockerPaired(data_.offerLocker, data_.servicer);

        uint256 n = data_.offerIds.length;
        for (uint256 i; i < n; ++i) {
            TermFinancePendingOffersStorageLib.removePendingOfferIfExists(data_.servicer, data_.offerIds[i]);
        }

        IExtTermAuctionOfferLocker(data_.offerLocker).unlockOffers(data_.offerIds);

        emit TermFinanceOfferUnlocked(VERSION, data_.servicer, data_.offerLocker, data_.offerIds);
    }

    /// @notice Reverts unless the vault has a WithdrawManager configured.
    /// @dev Mirror of `TermFinanceBidFuse._assertWithdrawManagerSet`. Reads directly from the
    ///      canonical storage slot via `PlasmaVaultStorageLib.getWithdrawManager()` — during
    ///      fuse delegatecall the slot is read from PlasmaVault storage (the intended context).
    function _assertWithdrawManagerSet() private view {
        if (PlasmaVaultStorageLib.getWithdrawManager().manager == address(0)) {
            revert TermFinanceOfferFuseWithdrawManagerRequired();
        }
    }

    /// @notice Combined substrate-allowlist + controller-isTermDeployed guard.
    /// @param servicer_ Substrate to check
    function _assertServicerAllowed(address servicer_) internal view {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, servicer_)) {
            revert TermFinanceOfferFuseUnsupportedMarket(servicer_);
        }
        if (!IExtTermController(TERM_CONTROLLER).isTermDeployed(servicer_)) {
            revert TermFinanceOfferFuseTermNotDeployed(servicer_);
        }
    }

    /// @notice Confirms the offerLocker passed in calldata is the one paired with `servicer_`
    ///         (impersonation guard against a contract exposing the same selectors).
    /// @dev The `termRepoServicer() == servicer_` pairing alone is spoofable — a
    ///      malicious alpha can deploy a contract whose `termRepoServicer()` returns the real
    ///      granted servicer, pass it as `offerLocker`, have `lockOffers` move no funds, and
    ///      record a phantom pending offer that inflates NAV (double-count vs the vault's
    ///      retained ERC20 balance). The servicer is anchored to governance via the substrate
    ///      allowlist + `isTermDeployed`, but the locker is NOT derivable from the servicer
    ///      (no getter), so we anchor it the same way: require the controller to recognise the
    ///      locker as a genuine Term deployment. Verified on Ethereum mainnet 2026-06-10 that
    ///      `isTermDeployed` returns true for live `TermAuctionOfferLocker` proxies.
    /// @param offerLocker_ Locker address passed in calldata
    /// @param servicer_ Substrate key
    function _assertOfferLockerPaired(address offerLocker_, address servicer_) internal view {
        if (!IExtTermController(TERM_CONTROLLER).isTermDeployed(offerLocker_)) {
            revert TermFinanceOfferFuseOfferLockerNotDeployed(offerLocker_);
        }
        address paired = IExtTermAuctionOfferLocker(offerLocker_).termRepoServicer();
        if (paired != servicer_) {
            revert TermFinanceOfferFuseOfferLockerMismatch(paired, servicer_);
        }
    }
}

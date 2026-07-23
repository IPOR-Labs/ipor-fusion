// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Errors} from "../../libraries/errors/Errors.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "../../libraries/PlasmaVaultStorageLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IExtTermAuctionOfferLocker} from "./ext/IExtTermAuctionOfferLocker.sol";
import {IExtTermController} from "./ext/IExtTermController.sol";

/// @notice Data for revealing previously committed sealed-bid offers.
/// @param servicer Substrate key — TermRepoServicer proxy
/// @param offerLocker Auction-paired TermAuctionOfferLocker proxy
/// @param offerIds Ids of locked offers to reveal
/// @param prices Plaintext rates in 18-dec mantissa, parallel to offerIds
/// @param nonces Nonces used in the commit hash, parallel to offerIds
struct TermFinanceOfferRevealFuseEnterData {
    address servicer;
    address offerLocker;
    bytes32[] offerIds;
    uint256[] prices;
    uint256[] nonces;
}

/// @title TermFinanceOfferRevealFuse
/// @author IPOR Labs
/// @notice Reveal offers during the reveal phase: the OfferLocker verifies
///         `keccak256(abi.encode(price, nonce)) == storedHash` per offerId and marks the
///         offer as revealed so it can be considered at `completeAuction` time.
/// @dev Reveal phase opens at `revealTime` and has no on-chain upper bound - the auction
///      is closed by the AUCTIONEER's `completeAuction` call. The IPOR off-chain keeper is
///      the responsibility-bearer for calling this fuse on time.
contract TermFinanceOfferRevealFuse is IFuseCommon {
    /// @notice Emitted when one or more offers are successfully revealed.
    event TermFinanceOffersRevealed(
        address version,
        address servicer,
        address offerLocker,
        bytes32[] offerIds,
        uint256[] prices
    );

    /// @notice Reverts when the PlasmaVault has no WithdrawManager configured.
    /// @dev Requires: a vault without a WithdrawManager
    ///      could allow LP withdrawals at any time, bypassing the Term Finance maturity timeline.
    ///      Mirror of `TermFinanceBidFuse.TermFinanceBidFuseWithdrawManagerRequired`.
    error TermFinanceOfferRevealFuseWithdrawManagerRequired();

    /// @notice Reverts when `servicer` is not in the vault substrate allowlist.
    error TermFinanceOfferRevealFuseUnsupportedMarket(address servicer);
    /// @notice Reverts when `controller.isTermDeployed(servicer)` returns false.
    error TermFinanceOfferRevealFuseTermNotDeployed(address servicer);
    /// @notice Reverts when the supplied offerLocker is paired with a different servicer than expected.
    /// @param expected Servicer the locker is actually paired with.
    /// @param actual Servicer supplied by the caller.
    error TermFinanceOfferRevealFuseOfferLockerMismatch(address expected, address actual);
    /// @notice Reverts when `controller.isTermDeployed(offerLocker)` returns false.
    /// @param offerLocker The locker that is not a Term-recognised deployment.
    error TermFinanceOfferRevealFuseOfferLockerNotDeployed(address offerLocker);
    /// @notice Reverts when no offer ids supplied.
    error TermFinanceOfferRevealFuseEmptyIds();
    /// @notice Reverts when `prices.length != offerIds.length` or `nonces.length != offerIds.length`.
    error TermFinanceOfferRevealFuseArrayLengthMismatch();

    /// @notice Address of this contract instance, used as the version identifier in event logs.
    address public immutable VERSION;
    /// @notice PlasmaVault market id assigned to Term Finance.
    uint256 public immutable MARKET_ID;
    /// @notice Live Term Finance `TermController` proxy.
    address public immutable TERM_CONTROLLER;

    /// @notice Initialise immutables.
    /// @param marketId_ PlasmaVault market id
    /// @param termController_ Term Finance evergreen controller proxy
    constructor(uint256 marketId_, address termController_) {
        if (marketId_ == 0) revert Errors.WrongValue();
        if (termController_ == address(0)) revert Errors.WrongAddress();

        VERSION = address(this);
        MARKET_ID = marketId_;
        TERM_CONTROLLER = termController_;
    }

    function enter(TermFinanceOfferRevealFuseEnterData calldata data_) external {
        _assertWithdrawManagerSet();
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.servicer)) {
            revert TermFinanceOfferRevealFuseUnsupportedMarket(data_.servicer);
        }
        if (!IExtTermController(TERM_CONTROLLER).isTermDeployed(data_.servicer)) {
            revert TermFinanceOfferRevealFuseTermNotDeployed(data_.servicer);
        }
        // Anchor the locker to the Term controller — `termRepoServicer()` pairing
        // alone is spoofable by a malicious alpha. Reveal moves no funds, but the guard is
        // kept symmetric with OfferFuse so a spoofed locker never reaches `revealOffers`.
        if (!IExtTermController(TERM_CONTROLLER).isTermDeployed(data_.offerLocker)) {
            revert TermFinanceOfferRevealFuseOfferLockerNotDeployed(data_.offerLocker);
        }
        address paired = IExtTermAuctionOfferLocker(data_.offerLocker).termRepoServicer();
        if (paired != data_.servicer) {
            revert TermFinanceOfferRevealFuseOfferLockerMismatch(paired, data_.servicer);
        }

        uint256 n = data_.offerIds.length;
        if (n == 0) revert TermFinanceOfferRevealFuseEmptyIds();
        if (data_.prices.length != n || data_.nonces.length != n) {
            revert TermFinanceOfferRevealFuseArrayLengthMismatch();
        }

        IExtTermAuctionOfferLocker(data_.offerLocker).revealOffers(data_.offerIds, data_.prices, data_.nonces);

        emit TermFinanceOffersRevealed(VERSION, data_.servicer, data_.offerLocker, data_.offerIds, data_.prices);
    }

    /// @notice Reverts unless the vault has a WithdrawManager configured.
    /// @dev Mirror of `TermFinanceBidFuse._assertWithdrawManagerSet`. Reads directly from the
    ///      canonical storage slot via `PlasmaVaultStorageLib.getWithdrawManager()` — during
    ///      fuse delegatecall the slot is read from PlasmaVault storage (the intended context).
    function _assertWithdrawManagerSet() private view {
        if (PlasmaVaultStorageLib.getWithdrawManager().manager == address(0)) {
            revert TermFinanceOfferRevealFuseWithdrawManagerRequired();
        }
    }
}

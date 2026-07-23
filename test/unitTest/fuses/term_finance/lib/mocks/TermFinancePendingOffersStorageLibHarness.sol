// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {TermFinancePendingOffersStorageLib} from "contracts/fuses/term_finance/lib/TermFinancePendingOffersStorageLib.sol";

/// @title TermFinancePendingOffersStorageLibHarness
/// @notice Exposes the internal library functions for unit testing. Each instance has
///         its own ERC-7201 namespace (shared globally per address by the library design,
///         but since the library reads from the calling-contract storage via assembly,
///         a fresh deployment of the harness gives a fresh slot).
contract TermFinancePendingOffersStorageLibHarness {
    function addPendingOffer(
        address servicer_,
        address offerLocker_,
        bytes32 offerId_,
        uint256 amount_
    ) external {
        TermFinancePendingOffersStorageLib.addPendingOffer(servicer_, offerLocker_, offerId_, amount_);
    }

    function removePendingOfferIfExists(address servicer_, bytes32 offerId_) external {
        TermFinancePendingOffersStorageLib.removePendingOfferIfExists(servicer_, offerId_);
    }

    function getPendingOffersForServicer(
        address servicer_
    ) external view returns (address[] memory offerLockers, bytes32[] memory offerIds, uint256[] memory amounts) {
        return TermFinancePendingOffersStorageLib.getPendingOffersForServicer(servicer_);
    }

    function getAllPendingServicers() external view returns (address[] memory) {
        return TermFinancePendingOffersStorageLib.getAllPendingServicers();
    }

    function isOfferPending(address servicer_, bytes32 offerId_) external view returns (bool) {
        return TermFinancePendingOffersStorageLib.isOfferPending(servicer_, offerId_);
    }

    function getOfferLocker(address servicer_, bytes32 offerId_) external view returns (address) {
        return TermFinancePendingOffersStorageLib.getOfferLocker(servicer_, offerId_);
    }
}

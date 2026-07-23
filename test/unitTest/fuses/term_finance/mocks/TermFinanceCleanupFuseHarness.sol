// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {TermFinanceCleanupFuse} from "contracts/fuses/term_finance/TermFinanceCleanupFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {TermFinancePendingOffersStorageLib} from "contracts/fuses/term_finance/lib/TermFinancePendingOffersStorageLib.sol";
import {TermFinancePendingBidsStorageLib} from "contracts/fuses/term_finance/lib/TermFinancePendingBidsStorageLib.sol";

contract TermFinanceCleanupFuseHarness is TermFinanceCleanupFuse {
    constructor(uint256 marketId_) TermFinanceCleanupFuse(marketId_) {}

    function setMarketSubstrates(uint256 marketId_, bytes32[] memory substrates_) external {
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, substrates_);
    }

    // ------------------------- offers helpers -------------------------

    function addPendingOffer(
        address servicer_,
        address offerLocker_,
        bytes32 offerId_,
        uint256 amount_
    ) external {
        TermFinancePendingOffersStorageLib.addPendingOffer(servicer_, offerLocker_, offerId_, amount_);
    }

    function isOfferPending(address servicer_, bytes32 offerId_) external view returns (bool) {
        return TermFinancePendingOffersStorageLib.isOfferPending(servicer_, offerId_);
    }

    function getPendingOffersForServicer(
        address servicer_
    ) external view returns (address[] memory offerLockers, bytes32[] memory offerIds, uint256[] memory amounts) {
        return TermFinancePendingOffersStorageLib.getPendingOffersForServicer(servicer_);
    }

    // ------------------------- bids helpers -------------------------

    function addPendingBid(
        address servicer_,
        address bidLocker_,
        bytes32 bidId_,
        uint256 amount_,
        address[] memory collateralTokens_,
        uint256[] memory collateralAmounts_
    ) external {
        TermFinancePendingBidsStorageLib.addPendingBid(
            servicer_,
            bidLocker_,
            bidId_,
            amount_,
            collateralTokens_,
            collateralAmounts_
        );
    }

    function isBidPending(address servicer_, bytes32 bidId_) external view returns (bool) {
        return TermFinancePendingBidsStorageLib.isBidPending(servicer_, bidId_);
    }

    function getPendingBidsForServicer(
        address servicer_
    )
        external
        view
        returns (
            address[] memory bidLockers,
            bytes32[] memory bidIds,
            uint256[] memory amounts,
            address[][] memory collateralTokens,
            uint256[][] memory collateralAmounts
        )
    {
        return TermFinancePendingBidsStorageLib.getPendingBidsForServicer(servicer_);
    }

    function pendingBidsLength(address servicer_) external view returns (uint256) {
        return TermFinancePendingBidsStorageLib.length(servicer_);
    }
}

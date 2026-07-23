// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {TermFinanceOfferFuse} from "contracts/fuses/term_finance/TermFinanceOfferFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {
    TermFinancePendingOffersStorageLib
} from "contracts/fuses/term_finance/lib/TermFinancePendingOffersStorageLib.sol";

contract TermFinanceOfferFuseHarness is TermFinanceOfferFuse {
    constructor(uint256 marketId_, address termController_) TermFinanceOfferFuse(marketId_, termController_) {}

    function setMarketSubstrates(uint256 marketId_, bytes32[] memory substrates_) external {
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, substrates_);
    }

    function isOfferPending(address servicer_, bytes32 offerId_) external view returns (bool) {
        return TermFinancePendingOffersStorageLib.isOfferPending(servicer_, offerId_);
    }

    function getPendingOffersForServicer(address servicer_)
        external
        view
        returns (address[] memory offerLockers, bytes32[] memory offerIds, uint256[] memory amounts)
    {
        return TermFinancePendingOffersStorageLib.getPendingOffersForServicer(servicer_);
    }

    function pendingOffersLength(address servicer_) external view returns (uint256) {
        return TermFinancePendingOffersStorageLib.length(servicer_);
    }
}

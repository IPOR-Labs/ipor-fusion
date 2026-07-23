// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {TermFinanceBalanceFuse} from "contracts/fuses/term_finance/TermFinanceBalanceFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "contracts/libraries/PlasmaVaultLib.sol";
import {TermFinancePendingBidsStorageLib} from "contracts/fuses/term_finance/lib/TermFinancePendingBidsStorageLib.sol";
import {TermFinancePendingOffersStorageLib} from "contracts/fuses/term_finance/lib/TermFinancePendingOffersStorageLib.sol";

/// @notice Inherits TermFinanceBalanceFuse so that `address(this)` in balanceOf is the
///         harness — mimicking the PlasmaVault delegatecall context. Exposes storage
///         setters so tests can set up substrates, price oracle, and pending offers/bids.
contract TermFinanceBalanceFuseHarness is TermFinanceBalanceFuse {
    constructor(
        uint256 marketId_,
        address termController_,
        address discountRateAdapter_
    ) TermFinanceBalanceFuse(marketId_, termController_, discountRateAdapter_) {}

    function setMarketSubstrates(uint256 marketId_, bytes32[] memory substrates_) external {
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, substrates_);
    }

    function setPriceOracleMiddleware(address oracle_) external {
        PlasmaVaultLib.setPriceOracleMiddleware(oracle_);
    }

    function addPendingOffer(
        address servicer_,
        address offerLocker_,
        bytes32 offerId_,
        uint256 amount_
    ) external {
        TermFinancePendingOffersStorageLib.addPendingOffer(servicer_, offerLocker_, offerId_, amount_);
    }

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
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {TermFinanceBidFuse} from "contracts/fuses/term_finance/TermFinanceBidFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {TermFinancePendingBidsStorageLib} from "contracts/fuses/term_finance/lib/TermFinancePendingBidsStorageLib.sol";

/// @notice Harness exposing internal substrate / storage configuration on `TermFinanceBidFuse`
///         for unit testing. Mirrors the `TermFinanceOfferFuseHarness` pattern.
contract TermFinanceBidFuseHarness is TermFinanceBidFuse {
    constructor(uint256 marketId_, address termController_) TermFinanceBidFuse(marketId_, termController_) {}

    /// @notice Direct write into the `MarketSubstrates` storage map (delegatecall context not
    ///         required for these tests because the harness `address(this)` IS the storage
    ///         context — substrates are written via the library which mutates the slot in
    ///         the calling contract's storage).
    function setMarketSubstrates(uint256 marketId_, bytes32[] memory substrates_) external {
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, substrates_);
    }

    function isBidPending(address servicer_, bytes32 bidId_) external view returns (bool) {
        return TermFinancePendingBidsStorageLib.isBidPending(servicer_, bidId_);
    }

    function getPendingBidsForServicer(address servicer_)
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

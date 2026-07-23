// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {TermFinancePendingBidsStorageLib} from "contracts/fuses/term_finance/lib/TermFinancePendingBidsStorageLib.sol";

/// @title TermFinancePendingBidsStorageLibHarness
/// @notice Exposes the internal library functions for unit testing. A fresh deployment
///         of the harness gives a fresh ERC-7201 slot (per harness-contract address),
///         so each test contract gets isolated state.
contract TermFinancePendingBidsStorageLibHarness {
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

    function removePendingBidIfExists(address servicer_, bytes32 bidId_) external {
        TermFinancePendingBidsStorageLib.removePendingBidIfExists(servicer_, bidId_);
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

    function getAllPendingServicers() external view returns (address[] memory) {
        return TermFinancePendingBidsStorageLib.getAllPendingServicers();
    }

    function length(address servicer_) external view returns (uint256) {
        return TermFinancePendingBidsStorageLib.length(servicer_);
    }

    function isBidPending(address servicer_, bytes32 bidId_) external view returns (bool) {
        return TermFinancePendingBidsStorageLib.isBidPending(servicer_, bidId_);
    }

    function getBidLocker(address servicer_, bytes32 bidId_) external view returns (address) {
        return TermFinancePendingBidsStorageLib.getBidLocker(servicer_, bidId_);
    }

    function maxPendingBidsPerServicer() external pure returns (uint256) {
        return TermFinancePendingBidsStorageLib.MAX_PENDING_BIDS_PER_SERVICER;
    }
}

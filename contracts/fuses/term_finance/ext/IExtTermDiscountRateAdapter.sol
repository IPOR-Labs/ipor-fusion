// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title Extended interface for Term Finance TermDiscountRateAdapter (Adapter-B shape)
/// @notice Targets the Curated Vaults adapter at 0x3C6b0398eEd7dAfcb3C13d482400329a6e25Acd2
///         which supports controller rotation via currTermController/prevTermController
///         and exposes the dual-form getDiscountRate overload.
interface IExtTermDiscountRateAdapter {
    function getDiscountRate(address repoToken) external view returns (uint256);

    function getDiscountRate(address termController, address repoToken) external view returns (uint256);

    function repoRedemptionHaircut(address repoToken) external view returns (uint256);

    function rateInvalid(address repoToken, bytes32 auctionId) external view returns (bool);

    function currTermController() external view returns (address);

    function prevTermController() external view returns (address);
}

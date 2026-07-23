// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title Extended interface for Term Finance TermRepoServicer
/// @notice Adds explicit declarations for concrete-only auto-getters (termRepoToken,
///         termRepoLocker, termRepoCollateralManager, shortfallHaircutMantissa) and
///         borrower-side state-changing selectors (submitRepurchasePayment,
///         burnCollapseExposure) needed by IPOR Fusion lender and borrower fuses.
/// @dev The four borrower-side additions are:
///      `submitRepurchasePayment`, `burnCollapseExposure`, `getBorrowerRepurchaseObligation`,
///      `termRepoCollateralManager`. Verified against the concrete `TermRepoServicer` contract
///      (public state variables and external/public functions).
interface IExtTermRepoServicer {
    function redeemTermRepoTokens(address redeemer, uint256 amountToRedeem) external;

    /// @notice Submit a borrower repurchase payment to settle (partially or fully) the
    ///         caller's repurchase obligation.
    /// @dev `msg.sender` is the borrower. During fuse delegatecall, this is the PlasmaVault.
    ///      The Servicer caps `amount` at the outstanding obligation natively (excess is
    ///      either refunded or rejected depending on the concrete implementation — confirm
    ///      via fuse pre/post balance delta).
    /// @param amount Purchase-token raw units to repay.
    function submitRepurchasePayment(uint256 amount) external;

    /// @notice Burn caller-held TermRepoTokens against the caller's borrower repurchase
    ///         obligation (early-debt-cancel via redemption of lender-side TermRepoToken).
    /// @dev Out of scope for v2 borrower implementation; declared here for completeness so
    ///      the interface mirrors the on-chain ABI. Caller is the borrower (PlasmaVault).
    /// @param amountToBurn TermRepoToken raw units to burn.
    function burnCollapseExposure(uint256 amountToBurn) external;

    /// @notice Outstanding repurchase obligation for a borrower, denominated in purchase-token
    ///         raw units at FACE value (not present value).
    /// @dev FACE value, NOT PV. The fuse-side PV calculation must apply the borrower-debt
    ///      discount via `TermFinancePresentValueLib.presentValueBorrowerDebt`.
    /// @param borrower Borrower address (PlasmaVault during fuse delegatecall).
    /// @return Outstanding face debt in purchase-token raw units.
    function getBorrowerRepurchaseObligation(address borrower) external view returns (uint256);

    function maturityTimestamp() external view returns (uint256);

    function redemptionTimestamp() external view returns (uint256);

    function endOfRepurchaseWindow() external view returns (uint256);

    function purchaseToken() external view returns (address);

    function termRepoToken() external view returns (address);

    function termRepoLocker() external view returns (address);

    /// @notice Paired `TermRepoCollateralManager` for this Term Repo.
    /// @dev Used by borrower-side fuses to validate the `collateralManager` passed via
    ///      calldata against the servicer pairing (impersonation guard). Mirrors the
    ///      `termRepoLocker()` getter pattern.
    /// @return TermRepoCollateralManager proxy address.
    function termRepoCollateralManager() external view returns (address);

    function shortfallHaircutMantissa() external view returns (uint256);
}

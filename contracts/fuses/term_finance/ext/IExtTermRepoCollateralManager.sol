// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title Extended interface for Term Finance TermRepoCollateralManager
/// @notice Adds explicit declarations for the borrower-side collateral lock / unlock
///         selectors and the read-side helpers required by IPOR Fusion borrower fuses.
/// @dev Verified against live impl `0x6A2E09F23Ef3a1f5ECEd9d4DAeD3b27d181F93e1` (v0.9.0)
///      via the proxy `0x9b00ee0b1cE01f74B1d18fAc682D4c9A3077C7d3` (USDC <-> PT-reUSD Term
///      Repo, maturity 2026-06-25) on Ethereum mainnet on 2026-05-15.
interface IExtTermRepoCollateralManager {
    /// @notice Lock additional collateral for `msg.sender` (the borrower).
    /// @dev `TermRepoCollateralManager.externalLockCollateral` pulls collateral via
    ///      `TermRepoLocker.transferTokenFromWallet(borrower, ...)`. Approval target is
    ///      `TermRepoLocker`, NOT this contract.
    /// @param collateralToken Allowlisted collateral token address.
    /// @param amount Raw token units to lock.
    function externalLockCollateral(address collateralToken, uint256 amount) external;

    /// @notice Unlock collateral previously locked by `msg.sender` (the borrower).
    /// @dev Subject to the maintenance margin invariant — reverts if unlock would push
    ///      the borrower below the maintenance collateral ratio.
    /// @param collateralToken Allowlisted collateral token address.
    /// @param amount Raw token units to unlock.
    function externalUnlockCollateral(address collateralToken, uint256 amount) external;

    /// @notice Raw collateral balance for `borrower` denominated in `collateralToken` units.
    /// @param borrower Borrower address (PlasmaVault during fuse delegatecall context).
    /// @param collateralToken Allowlisted collateral token address.
    /// @return Collateral balance in raw token units (NOT USD-normalised).
    function getCollateralBalance(address borrower, address collateralToken) external view returns (uint256);

    /// @notice True iff the borrower is currently under-collateralised against the
    ///         maintenance margin ratio (i.e. eligible for liquidation).
    /// @param borrower Borrower address.
    /// @return True if the borrower is in shortfall.
    function isBorrowerInShortfall(address borrower) external view returns (bool);

    /// @notice WAD-USD aggregate market value of all collateral for `borrower`, priced at
    ///         Term Finance's internal oracle (`TermPriceConsumerV3`).
    /// @dev VERIFIED: returns an 18-decimal mantissa even when the underlying collateral
    ///      token has different precision (e.g. live read returned `1.137e24` for a
    ///      6-decimal collateral token). This value is suitable for borrower-shortfall
    ///      sanity checks ONLY — for NAV in the IPOR balance fuse, enumerate collateral
    ///      tokens and price each via the IPOR `PriceOracleMiddleware` (NOT this getter)
    ///      to avoid thin-feed manipulation risk on the Term-internal oracle.
    /// @param borrower Borrower address.
    /// @return Aggregate collateral market value in WAD-USD (18 decimals).
    function getCollateralMarketValue(address borrower) external view returns (uint256);

    /// @notice Maintenance collateral ratio for a specific collateral token.
    /// @dev Returned in mantissa form (e.g. `1.0929e18` = 109.29%).
    /// @param collateralToken Allowlisted collateral token address.
    /// @return Maintenance collateral ratio (WAD mantissa).
    function maintenanceCollateralRatios(address collateralToken) external view returns (uint256);

    /// @notice Initial collateral ratio for a specific collateral token.
    /// @dev Returned in mantissa form (e.g. `1.1236e18` = 112.36%). Borrowers must
    ///      open positions at the initial ratio; the lower maintenance ratio applies
    ///      to ongoing solvency checks.
    /// @param collateralToken Allowlisted collateral token address.
    /// @return Initial collateral ratio (WAD mantissa).
    function initialCollateralRatios(address collateralToken) external view returns (uint256);

    /// @notice Per-token liquidation damage (penalty) applied when the borrower is
    ///         liquidated against this collateral.
    /// @param collateralToken Allowlisted collateral token address.
    /// @return Liquidation damage (WAD mantissa).
    function liquidatedDamage(address collateralToken) external view returns (uint256);

    /// @notice Number of accepted collateral tokens.
    /// @dev VERIFIED: return type is `uint8` on the concrete impl (NOT `uint256`). The
    ///      balance fuse loop bound MUST use this value, NOT a try/catch over
    ///      `collateralTokens(i)` (which reverts on OOB).
    /// @return Number of accepted collateral tokens.
    function numOfAcceptedCollateralTokens() external view returns (uint8);

    /// @notice Indexed accessor over the accepted-collateral list.
    /// @dev VERIFIED: REVERTS on out-of-bounds (does NOT return `address(0)`). Callers
    ///      MUST bound the loop with `i < numOfAcceptedCollateralTokens()` and MUST NOT
    ///      rely on a try/catch fallback to detect end-of-list — that would mask real
    ///      proxy breakage.
    /// @param index Zero-based index into the accepted-collateral list.
    /// @return Collateral token address at `index`.
    function collateralTokens(uint256 index) external view returns (address);
}

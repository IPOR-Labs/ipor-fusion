// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title Backed size of WithdrawManager requests, kept by the PlasmaVault (IL-9531)
/// @notice The cap of an account bounds what its WithdrawManager request can redeem: the lowest balance the account has
/// had since its last request, never above that request. The vault keeps it next to the balances so that every share
/// debit can lower it without an external call. All rules that use it live in the WithdrawManager. Deploy PlasmaVault, PlasmaVaultBase (its _update
/// lowers the caps) and WithdrawManager from the same release: with an older PlasmaVaultBase the caps never go down
interface IPlasmaVaultRequestCap {
    /// @notice Sets the cap of `account_` for its new request
    /// @dev Only the vault's WithdrawManager, from requestShares, after it has checked the balance. A later debit that
    /// leaves `account_` below the cap lowers it to that balance; a credit never raises it
    /// @param account_ The account that filed the request
    /// @param shares_ The shares recorded in the request (after the request fee)
    function setRequestCap(address account_, uint256 shares_) external;

    /// @notice Returns the cap of `account_`. Its current request can redeem at most min(request shares, cap)
    /// @dev The cap is not cleared when the request is used up or its window ends, so it can stay above zero then
    /// @param account_ The account to query
    /// @return The cap in vault shares, 0 when the account never filed a request or its backing left
    function getRequestCap(address account_) external view returns (uint256);
}

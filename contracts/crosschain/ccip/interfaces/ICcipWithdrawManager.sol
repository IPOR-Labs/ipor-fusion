// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @notice Mirror of the WithdrawManager request view (`WithdrawManager.WithdrawRequestInfo`), field for field, so the
///         dispatcher can decode `requestInfo` without importing the manager.
/// @dev `shares` is the manager's outstanding request, `endWithdrawWindowTimestamp` the end of the window in which it
///      can be redeemed, `canWithdraw` whether that window is open now, `withdrawWindowInSeconds` the window length.
struct CcipWithdrawRequestInfo {
    uint256 shares;
    uint256 endWithdrawWindowTimestamp;
    bool canWithdraw;
    uint256 withdrawWindowInSeconds;
}

/// @notice The two WithdrawManager entry points the dispatcher calls on a remote vault's manager (from its linked
///         `CcipDispatcherLib.requestShares`, IL-9621).
interface ICcipWithdrawManager {
    /// @notice Registers (replaces) the caller's withdraw request for `shares_` vault shares; refused while the
    ///         previous request is released and inside its window (IL-9652).
    function requestShares(uint256 shares_) external;
    /// @notice The manager's stored request of `account_`.
    function requestInfo(address account_) external view returns (CcipWithdrawRequestInfo memory);
}

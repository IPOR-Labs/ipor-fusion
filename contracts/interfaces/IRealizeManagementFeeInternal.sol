// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IRealizeManagementFeeInternal
/// @author IPOR Labs
/// @notice Minimal interface of the fuse entry that PlasmaVault versions built with IL-8870 expose
/// @dev The vault accepts the call only from itself (`msg.sender == address(this)`) while `PlasmaVault.execute`
///      runs, and the entry only returns the result of the vault's own `_realizeManagementFee()` (the code that
///      deposits, withdrawals and the ALPHA method `realizeManagementFee()` run). Like `executeInternal`, the entry
///      is not part of `IPlasmaVault`. Vault versions without the entry answer this selector during `execute`
///      through the fallback with `CallbackHandlerLib.HandlerNotFound()`.
interface IRealizeManagementFeeInternal {
    /// @notice Realizes the accrued management fee of the vault
    /// @return feeShares Management fee shares minted to the management fee account
    function realizeManagementFeeInternal() external returns (uint256 feeShares);
}

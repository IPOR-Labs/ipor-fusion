// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IStargateDispatcherLibraryAbi
/// @notice ABI declarations for errors raised by CrosschainVaultActionLib and StargateDispatcherLib (and the events of CrosschainVaultActionLib) that StargateCrosschainDispatcher does not declare itself.
/// @dev Declarations only. Linked libraries run under delegatecall, so their events/errors are
///      emitted/raised from the host address but only appear in the host ABI if declared here.
///      Adds no runtime bytecode. Kept complete by CrosschainLibraryAbiCompletenessTest.
/// @author IPOR Labs
interface IStargateDispatcherLibraryAbi {
    /// @notice Emitted by `CrosschainVaultActionLib.sweepShares` when a vault leaving the allowlist is redeemed (IL-8784).
    event TrackedVaultSwept(address vault, uint256 sharesRedeemed, uint256 assetsLD);
    /// @notice Emitted by `CrosschainVaultActionLib.sweepShares` when shares of a removed vault stay on the dispatcher:
    ///         `reason` 1 = balance unreadable, 2 = `redeem` reverted (`redeemError` = first 4 revert bytes),
    ///         3 = partial redeem, 4 = dust skipped (no `redeem` call, D-061),
    ///         5 = `redeem` failed with less than the full sweep gas forwarded (D-065; not necessarily a gas failure, read `redeemError`),
    ///         6 = a non-zero sweep floor was not reached and nothing was burned (IL-9629), or the `redeem` reverted
    ///         WITH error data and burned nothing under that floor (IL-9694 D-002). `untracked` is true for 1-5
    ///         (D-028) and false for 6: the vault stays tracked, off the allowlist, and keeps counting in NAV.
    event TrackedVaultSweepResidual(
        address vault,
        uint256 sharesLeft,
        uint8 reason,
        bytes4 redeemError,
        bool untracked
    );

    error AddressReadFailed();
    /// @dev Raised by `StargateDispatcherLib.runBusinessAction` (DEPOSIT, REDEEM and REDEEM_FROM_REQUEST bodies).
    error ZeroAmount();
    error ReceiverMustBeSelf(address receiver);
    error VaultAssetDrifted(address vault, address actual);
    error VaultNotAllowed(address vault);
    error InsufficientAssets(uint256 got, uint256 min);
    error InsufficientShares(uint256 got, uint256 min);
    error VaultsCapReached(uint256 max);
    error DepositMintedNoShares(address vault, uint256 assets);
    /// @dev Raised by `CrosschainVaultActionLib.redeemAtLeast` inside the `sweepRedeemSelf` frame and caught (IL-9629).
    error SweepBelowMinimum(address vault, uint256 receivedLD, uint256 minAssetsLD);
    error InvalidVault(address vault);
    error RescueLedgerInvariantViolation(uint256 balance, uint256 tracked);
    error WithdrawManagerMismatch(address withdrawManager, address plasmaVault);
    error WithdrawManagerUnresolved(address plasmaVault);
}

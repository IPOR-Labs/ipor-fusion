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
    ///         5 = `redeem` failed with less than the full sweep gas forwarded (D-065; not necessarily a gas failure, read `redeemError`). `untracked` is always true (D-028).
    event TrackedVaultSweepResidual(
        address vault,
        uint256 sharesLeft,
        uint8 reason,
        bytes4 redeemError,
        bool untracked
    );

    error AddressReadFailed();
    error DepositMintedNoShares(address vault, uint256 assets);
    error InvalidVault(address vault);
    error RescueLedgerInvariantViolation(uint256 balance, uint256 tracked);
    error WithdrawManagerMismatch(address withdrawManager, address plasmaVault);
    error WithdrawManagerUnresolved(address plasmaVault);
}

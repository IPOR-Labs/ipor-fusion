// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @notice Canonical dispatcher observation. Keepers derive attestations from this view at
///         the reported remote block; removed-but-live vaults remain included. Amounts are in local
///         ASSET decimals per §4.1.
/// @param trackedIdle Tracked remote idle ASSET (local decimals).
/// @param trackedVaults The tracked-position vault set: vaults holding live shares, removed-but-live included
///        (the deposit allowlist is kept apart, see `getAllowedVaults`).
/// @param vaultAssetValues Per-vault `convertToAssets(balanceOf(dispatcher))` (local decimals), aligned
///        with `trackedVaults`.
/// @param stateVersion Monotonic dispatcher state version.
/// @param commandConfigEpoch Current deposit-allowlist config epoch.
/// @param trackedPositionSetHash Hash binding the tracked-position set.
/// @param vaultValued Per-vault flag aligned with `trackedVaults`: false when the vault's `balanceOf` /
///        `asset` / `convertToAssets` read failed or `asset() != ASSET` (IL-8645, IL-8602). Its `vaultAssetValues` entry is then 0 and the position is NOT in
///        any aggregate built from this view, so an attester must treat the observation as degraded.
/// @param unpricedCount Number of `false` entries in `vaultValued`.
struct Observation {
    uint256 trackedIdle;
    address[] trackedVaults;
    uint256[] vaultAssetValues;
    uint64 stateVersion;
    uint64 commandConfigEpoch;
    bytes32 trackedPositionSetHash;
    bool[] vaultValued;
    uint256 unpricedCount;
}

/// @title ICrosschainDispatcher
/// @notice Locked view surface of the crosschain dispatcher. Lives on a remote chain at the
///         same address as its executor; has NO manager — only authenticated crosschain messages act, apart
///         from the rescue admin's timelocked exits.
/// @dev Implemented by `StargateCrosschainDispatcher` (the CCIP dispatcher has its own `observation()`). First
///      cut: the concrete contract adds rescue (via `RescueModule`, incl. the timelocked admin recall and
///      force-untrack) and the inbound transport handlers (`lzReceive` commands/recall lane, `lzCompose` inbound
///      asset settle).
/// @author IPOR Labs
interface ICrosschainDispatcher {
    /// @notice The canonical observation used to derive NAV attestations.
    function observation() external view returns (Observation memory);

    /// @notice The current monotonic dispatcher state version.
    function stateVersion() external view returns (uint64);

    /// @dev `ASSET()` is intentionally NOT declared here: the transport base already exposes it as a
    ///      public immutable getter, and a non-virtual base getter cannot be reconciled with an
    ///      interface method in the deriving contract. `ASSET()` remains present in the concrete
    ///      dispatcher's ABI (inherited from `StargateOAppBase`).

    /// @notice The chain id of the single executor authorized to command this dispatcher.
    function EXECUTOR_CHAIN_ID() external view returns (uint256);
}

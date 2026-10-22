// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @title CrosschainRecoveryContextTestLib
/// @notice TEST-ONLY helper that wipes the transient recovery context owned by
///         `contracts/fuses/crosschain/lib/CrosschainRecoveryLib.sol`.
/// @dev Lives under `test/` on purpose. Production code has no reason to clear this context — the
///      accumulator is rebased against the persisted market cache by `markRecovery`, and the flags are
///      transaction-scoped by design — so exposing a clear function from the production library would be
///      dead weight in every deployed fuse and an invitation to call it on-chain.
///
///      The slot constants are DUPLICATED from `CrosschainRecoveryLib` (they are `private` there). They
///      are `keccak256` of stable, human-readable strings; `CrosschainRecoveryLibSlotsTest` asserts that
///      this copy still matches the production library's observable behaviour, so a renamed slot fails
///      loudly instead of silently turning every `clearContext(marketId)` in the harness into a no-op.
library CrosschainRecoveryContextTestLib {
    bytes32 private constant _RECOVERY_SLOT = keccak256("ipor.fusion.crosschain.recovery.active");
    bytes32 private constant _EXPOSURE_SLOT = keccak256("ipor.fusion.crosschain.exposure.active");
    bytes32 private constant _RECOVERED_USD_SLOT = keccak256("ipor.fusion.crosschain.recovered.usd");
    bytes32 private constant _CACHE_SNAPSHOT_SLOT = keccak256("ipor.fusion.crosschain.recovery.cacheSnapshot");

    /// @notice Models the boundary between two separate top-level transactions in a single test.
    /// @dev The recovered-USD accumulator and the cache snapshot are keyed per market in production
    ///      (`keccak256(abi.encode(baseSlot, marketId))`), so the market being modelled must be passed.
    function clearContext(uint256 marketId_) internal {
        bytes32 recoverySlot = _RECOVERY_SLOT;
        bytes32 exposureSlot = _EXPOSURE_SLOT;
        bytes32 recoveredSlot = keccak256(abi.encode(_RECOVERED_USD_SLOT, marketId_));
        bytes32 snapshotSlot = keccak256(abi.encode(_CACHE_SNAPSHOT_SLOT, marketId_));
        assembly {
            tstore(recoverySlot, 0)
            tstore(exposureSlot, 0)
            tstore(recoveredSlot, 0)
            tstore(snapshotSlot, 0)
        }
    }
}

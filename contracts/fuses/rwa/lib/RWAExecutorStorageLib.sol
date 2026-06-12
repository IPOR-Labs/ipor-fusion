// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IRWAExecutor} from "../IRWAExecutor.sol";
import {RWAExecutor} from "../RWAExecutor.sol";
import {RWAErrors} from "../errors/RWAErrors.sol";

/// @title RWAExecutorStorageLib
/// @notice ERC-7201 namespaced storage library for the RWA fuse family. Runs in the
///         PlasmaVault's delegatecall context. Persists per-vault state shared between
///         `RWAOperationFuse`, `RWABalanceFuse`, `RWAPausePreHook`, `RWAUnpauseFuse`, and `RWARescueFuse`.
/// @dev Slot derivation:
///      `slot = keccak256(abi.encode(uint256(keccak256("io.ipor.rwa.Executor")) - 1)) & ~bytes32(uint256(0xff))`.
/// @author IPOR Labs
library RWAExecutorStorageLib {
    /// @dev Pre-computed ERC-7201 storage slot for the namespaced `RWAStorage` struct.
    bytes32 private constant _RWA_STORAGE_SLOT = 0x2c33642f9f95a2ae96c65138627f6a55480cec20290d678b3efcc2db4caa9400;

    /// @notice Emitted when the executor address is bound to this vault's RWA storage.
    /// @param executor Address of the deployed `RWAExecutor`.
    /// @param marketId Market identifier bound to the executor.
    event RWAExecutorDeployed(address executor, uint256 marketId);

    /// @notice Persistent RWA state per vault.
    /// @custom:storage-location erc7201:io.ipor.rwa.Executor
    struct RWAStorage {
        /// @dev Deployed `RWAExecutor` address (zero until first deploy).
        address executor;
        /// @dev Last total balance (underlying units) observed by the balance fuse; used for big-change detection.
        uint256 lastTotalBalance;
        /// @dev Last `lastCustodianUpdateTimestamp` observed by the balance fuse.
        uint256 lastCheckedCustodianTimestamp;
        /// @dev Pause flag; when true the RWA pre-hook blocks gated user operations.
        bool paused;
        /// @dev Set of unpause nonces already consumed by atomist signatures.
        mapping(uint256 => bool) usedUnpauseNonces;
    }

    /// @notice Load the ERC-7201 namespaced storage pointer.
    /// @return storagePtr Pointer to the `RWAStorage` struct.
    function getRwaStorage() internal pure returns (RWAStorage storage storagePtr) {
        assembly {
            storagePtr.slot := _RWA_STORAGE_SLOT
        }
    }

    // ============================================================
    // Executor address
    // ============================================================

    /// @notice Read the deployed executor address from vault storage.
    /// @return executorAddress Deployed executor address, or `address(0)` if not yet deployed.
    function getExecutor() internal view returns (address executorAddress) {
        executorAddress = getRwaStorage().executor;
    }

    /// @notice Overwrite the stored executor address.
    /// @param executor_ The new executor address.
    function setExecutor(address executor_) internal {
        getRwaStorage().executor = executor_;
    }

    /// @notice Lazily deploy the executor for this vault if none is stored, otherwise return the existing one.
    /// @dev If an executor already exists and is bound to a different `MARKET_ID`, reverts with
    ///      `RWAMultipleMarketsNotSupported` (decision Q5). When a new executor is deployed, `syncSubstrates()`
    ///      is invoked immediately so the executor starts with a populated cache.
    /// @param marketId_ Market identifier the executor must serve.
    /// @return executorAddress The (possibly newly-deployed) executor address bound to this vault.
    function getOrCreateExecutor(uint256 marketId_) internal returns (address executorAddress) {
        RWAStorage storage s = getRwaStorage();
        executorAddress = s.executor;

        if (executorAddress == address(0)) {
            RWAExecutor deployed = new RWAExecutor(marketId_, address(this));
            executorAddress = address(deployed);
            s.executor = executorAddress;
            // Populate caches from the vault substrate grants right after deployment.
            deployed.syncSubstrates();
            emit RWAExecutorDeployed(executorAddress, marketId_);
        } else {
            uint256 existingMarketId = IRWAExecutor(executorAddress).MARKET_ID();
            if (existingMarketId != marketId_) {
                revert RWAErrors.RWAMultipleMarketsNotSupported(existingMarketId, marketId_);
            }
        }
    }

    // ============================================================
    // Balance-fuse cache
    // ============================================================

    /// @notice Last observed total balance from `RWAExecutor.getBalanceFuseSnapshot()`.
    function getLastTotalBalance() internal view returns (uint256 value) {
        value = getRwaStorage().lastTotalBalance;
    }

    /// @notice Persist the last observed total balance.
    /// @param value_ The new value.
    function setLastTotalBalance(uint256 value_) internal {
        getRwaStorage().lastTotalBalance = value_;
    }

    /// @notice Last `lastCustodianUpdateTimestamp` observed by the balance fuse.
    function getLastCheckedCustodianTimestamp() internal view returns (uint256 value) {
        value = getRwaStorage().lastCheckedCustodianTimestamp;
    }

    /// @notice Persist the last observed custodian timestamp.
    /// @param value_ The new value.
    function setLastCheckedCustodianTimestamp(uint256 value_) internal {
        getRwaStorage().lastCheckedCustodianTimestamp = value_;
    }

    // ============================================================
    // Pause flag
    // ============================================================

    /// @notice Read the pause flag.
    function getPaused() internal view returns (bool value) {
        value = getRwaStorage().paused;
    }

    /// @notice Set the pause flag.
    /// @param value_ New pause state.
    function setPaused(bool value_) internal {
        getRwaStorage().paused = value_;
    }

    // ============================================================
    // Unpause nonces
    // ============================================================

    /// @notice Returns whether an unpause nonce has already been consumed.
    /// @param nonce_ Nonce to inspect.
    function isUnpauseNonceUsed(uint256 nonce_) internal view returns (bool value) {
        value = getRwaStorage().usedUnpauseNonces[nonce_];
    }

    /// @notice Mark an unpause nonce as consumed. Reverts silently on double-use; the caller
    ///         is expected to check `isUnpauseNonceUsed` before invoking this.
    /// @param nonce_ Nonce to mark as used.
    function markUnpauseNonceUsed(uint256 nonce_) internal {
        getRwaStorage().usedUnpauseNonces[nonce_] = true;
    }
}

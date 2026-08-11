// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IExternalStateExecutor} from "../IExternalStateExecutor.sol";
import {ExternalStateExecutor} from "../ExternalStateExecutor.sol";
import {ExternalStateErrors} from "../errors/ExternalStateErrors.sol";
import {PlasmaVaultConfigLib} from "../../../libraries/PlasmaVaultConfigLib.sol";

/// @title ExternalStateExecutorStorageLib
/// @notice ERC-7201 namespaced storage library for the ExternalState fuse family. Runs in the
///         PlasmaVault's delegatecall context. Persists per-vault state shared between
///         `ExternalStateOperationFuse`, `ExternalStateBalanceFuse`, `ExternalStatePausePreHook`, `ExternalStateUnpauseFuse`, and `ExternalStateRescueFuse`.
/// @dev Slot derivation:
///      `slot = keccak256(abi.encode(uint256(keccak256("io.ipor.externalState.Executor")) - 1)) & ~bytes32(uint256(0xff))`.
/// @author IPOR Labs
library ExternalStateExecutorStorageLib {
    /// @dev Pre-computed ERC-7201 storage slot for the namespaced `ExternalStateStorage` struct.
    bytes32 private constant _EXTERNAL_STATE_STORAGE_SLOT = 0x1781023874512ec457c16827ad102f41a5c5ce1cd7ba8aa8fcd2da52541d8a00;

    /// @notice Emitted when the executor address is bound to this vault's ExternalState storage.
    /// @param executor Address of the deployed `ExternalStateExecutor`.
    /// @param marketId Market identifier bound to the executor.
    event ExternalStateExecutorDeployed(address executor, uint256 marketId);

    /// @notice Persistent ExternalState state per vault.
    /// @custom:storage-location erc7201:io.ipor.externalState.Executor
    struct ExternalStateStorage {
        /// @dev Deployed `ExternalStateExecutor` address (zero until first deploy).
        address executor;
        /// @dev Last total balance (underlying units) observed by the balance fuse; used for big-change detection.
        uint256 lastTotalBalance;
        /// @dev Last `lastCustodianUpdateTimestamp` observed by the balance fuse.
        uint256 lastCheckedCustodianTimestamp;
        /// @dev Pause flag; when true the ExternalState pre-hook blocks gated user operations.
        bool paused;
        /// @dev Set of unpause nonces already consumed by atomist signatures.
        mapping(uint256 => bool) usedUnpauseNonces;
    }

    /// @notice Load the ERC-7201 namespaced storage pointer.
    /// @return storagePtr Pointer to the `ExternalStateStorage` struct.
    function getExternalStateStorage() internal pure returns (ExternalStateStorage storage storagePtr) {
        assembly {
            storagePtr.slot := _EXTERNAL_STATE_STORAGE_SLOT
        }
    }

    // ============================================================
    // Executor address
    // ============================================================

    /// @notice Read the deployed executor address from vault storage.
    /// @return executorAddress Deployed executor address, or `address(0)` if not yet deployed.
    function getExecutor() internal view returns (address executorAddress) {
        executorAddress = getExternalStateStorage().executor;
    }

    /// @notice Overwrite the stored executor address.
    /// @param executor_ The new executor address.
    function setExecutor(address executor_) internal {
        getExternalStateStorage().executor = executor_;
    }

    /// @notice Lazily deploy the executor for this vault if none is stored, otherwise return the existing one.
    /// @dev If an executor already exists and is bound to a different `MARKET_ID`, reverts with
    ///      `ExternalStateMultipleMarketsNotSupported` (decision Q5). When a new executor is deployed, the substrates are
    ///      read directly from vault storage (this library runs in the vault's delegatecall context) and pushed
    ///      into the executor via `setSubstrates`, so it starts with a populated cache. The push direction matters:
    ///      while `PlasmaVault.execute` is running, the vault's fallback rejects external callbacks into the vault,
    ///      so the executor cannot pull them via `getMarketSubstrates`.
    /// @param marketId_ Market identifier the executor must serve.
    /// @return executorAddress The (possibly newly-deployed) executor address bound to this vault.
    function getOrCreateExecutor(uint256 marketId_) internal returns (address executorAddress) {
        ExternalStateStorage storage s = getExternalStateStorage();
        executorAddress = s.executor;

        if (executorAddress == address(0)) {
            ExternalStateExecutor deployed = new ExternalStateExecutor(marketId_, address(this));
            executorAddress = address(deployed);
            s.executor = executorAddress;
            // Populate caches from the vault substrate grants right after deployment. Read from
            // vault storage and push — pulling via getMarketSubstrates would hit the vault's
            // callback-only fallback when running inside PlasmaVault.execute.
            deployed.setSubstrates(PlasmaVaultConfigLib.getMarketSubstrates(marketId_));
            emit ExternalStateExecutorDeployed(executorAddress, marketId_);
        } else {
            uint256 existingMarketId = IExternalStateExecutor(executorAddress).MARKET_ID();
            if (existingMarketId != marketId_) {
                revert ExternalStateErrors.ExternalStateMultipleMarketsNotSupported(existingMarketId, marketId_);
            }
        }
    }

    // ============================================================
    // Balance-fuse cache
    // ============================================================

    /// @notice Last observed total balance from `ExternalStateExecutor.getBalanceFuseSnapshot()`.
    function getLastTotalBalance() internal view returns (uint256 value) {
        value = getExternalStateStorage().lastTotalBalance;
    }

    /// @notice Persist the last observed total balance.
    /// @param value_ The new value.
    function setLastTotalBalance(uint256 value_) internal {
        getExternalStateStorage().lastTotalBalance = value_;
    }

    /// @notice Last `lastCustodianUpdateTimestamp` observed by the balance fuse.
    function getLastCheckedCustodianTimestamp() internal view returns (uint256 value) {
        value = getExternalStateStorage().lastCheckedCustodianTimestamp;
    }

    /// @notice Persist the last observed custodian timestamp.
    /// @param value_ The new value.
    function setLastCheckedCustodianTimestamp(uint256 value_) internal {
        getExternalStateStorage().lastCheckedCustodianTimestamp = value_;
    }

    // ============================================================
    // Pause flag
    // ============================================================

    /// @notice Read the pause flag.
    function getPaused() internal view returns (bool value) {
        value = getExternalStateStorage().paused;
    }

    /// @notice Set the pause flag.
    /// @param value_ New pause state.
    function setPaused(bool value_) internal {
        getExternalStateStorage().paused = value_;
    }

    // ============================================================
    // Unpause nonces
    // ============================================================

    /// @notice Returns whether an unpause nonce has already been consumed.
    /// @param nonce_ Nonce to inspect.
    function isUnpauseNonceUsed(uint256 nonce_) internal view returns (bool value) {
        value = getExternalStateStorage().usedUnpauseNonces[nonce_];
    }

    /// @notice Mark an unpause nonce as consumed. Reverts silently on double-use; the caller
    ///         is expected to check `isUnpauseNonceUsed` before invoking this.
    /// @param nonce_ Nonce to mark as used.
    function markUnpauseNonceUsed(uint256 nonce_) internal {
        getExternalStateStorage().usedUnpauseNonces[nonce_] = true;
    }
}

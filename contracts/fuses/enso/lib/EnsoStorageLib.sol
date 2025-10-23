// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title EnsoStorageLib
/// @notice Library for managing Enso executor storage in Plasma Vault
/// @dev Implements storage pattern using an isolated storage slot to maintain executor address
library EnsoStorageLib {
    /// @dev Storage slot for Enso executor address
    /// @dev Calculation: keccak256(abi.encode(uint256(keccak256("io.ipor.enso.Executor")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant ENSO_EXECUTOR_SLOT = 0x2be19acf1082fe0f31c0864ff2dc58ff9679d12ca8fb47a012400b2f6ce3af00;

    /// @dev Structure holding the Enso executor address
    /// @custom:storage-location erc7201:io.ipor.enso.Executor
    struct EnsoExecutorStorage {
        /// @dev The address of the Enso executor
        address executor;
    }

    /// @notice Gets the Enso executor storage pointer
    /// @return storagePtr The EnsoExecutorStorage struct from storage
    function getEnsoExecutorStorage() internal pure returns (EnsoExecutorStorage storage storagePtr) {
        assembly {
            storagePtr.slot := ENSO_EXECUTOR_SLOT
        }
    }

    /// @notice Sets the Enso executor address
    /// @param executor_ The address of the Enso executor
    function setEnsoExecutor(address executor_) internal {
        EnsoExecutorStorage storage storagePtr = getEnsoExecutorStorage();
        storagePtr.executor = executor_;
    }

    /// @notice Gets the Enso executor address
    /// @return The address of the Enso executor
    function getEnsoExecutor() internal view returns (address) {
        EnsoExecutorStorage storage storagePtr = getEnsoExecutorStorage();
        return storagePtr.executor;
    }
}

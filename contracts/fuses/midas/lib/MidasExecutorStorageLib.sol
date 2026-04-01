// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {MidasExecutor} from "../MidasExecutor.sol";

/// @title MidasExecutorStorageLib
/// @notice ERC-7201 namespaced storage library for storing the MidasExecutor address
/// @dev Runs in PlasmaVault's delegatecall context. Stores the executor address used
///      to hold assets during asynchronous Midas redemption operations.
library MidasExecutorStorageLib {
    /// @dev Storage slot for MidasExecutor address
    /// @dev Uses ERC-7201 namespaced storage pattern to avoid storage collisions.
    ///      Calculation: keccak256(abi.encode(uint256(keccak256("io.ipor.midas.Executor")) - 1)) & ~bytes32(uint256(0xff))
    ///      The slot is calculated by: namespace hash - 1, then clearing the last byte to align to 256-bit boundary.
    bytes32 private constant MIDAS_EXECUTOR_SLOT =
        0x70d197bb241b100c004ed80fc4b87ce41500fa5c47b2ad133730792ea68d7d00;

    /// @dev Structure holding the MidasExecutor address
    /// @custom:storage-location erc7201:io.ipor.midas.Executor
    struct MidasExecutorStorage {
        /// @dev The address of the MidasExecutor
        address executor;
    }

    /// @notice Gets the MidasExecutor storage pointer
    /// @return storagePtr The MidasExecutorStorage struct from storage
    /// @dev Uses inline assembly to access the namespaced storage slot.
    function getExecutorStorage() internal pure returns (MidasExecutorStorage storage storagePtr) {
        assembly {
            storagePtr.slot := MIDAS_EXECUTOR_SLOT
        }
    }

    /// @notice Gets the MidasExecutor address from storage
    /// @return executorAddress The address of the MidasExecutor, or address(0) if not set
    /// @dev Returns the executor address stored in the ERC-7201 namespaced storage slot.
    function getExecutor() internal view returns (address executorAddress) {
        MidasExecutorStorage storage storagePtr = getExecutorStorage();
        executorAddress = storagePtr.executor;
    }

    /// @notice Sets the MidasExecutor address
    /// @param executor_ The address of the MidasExecutor to store
    /// @dev Overwrites any previously stored executor address.
    function setExecutor(address executor_) internal {
        MidasExecutorStorage storage storagePtr = getExecutorStorage();
        storagePtr.executor = executor_;
    }

    /// @notice Gets the MidasExecutor address, deploying a new one if it doesn't exist
    /// @param plasmaVault_ Address of the controlling Plasma Vault (must not be address(0))
    /// @return executorAddress The address of the MidasExecutor
    /// @dev If executor doesn't exist in storage, deploys a new MidasExecutor and stores its address.
    ///      The executor is deployed with the provided Plasma Vault address.
    ///      Note: Input validation is performed by MidasExecutor constructor
    function getOrCreateExecutor(address plasmaVault_) internal returns (address executorAddress) {
        executorAddress = getExecutor();

        if (executorAddress == address(0)) {
            executorAddress = address(new MidasExecutor(plasmaVault_));
            setExecutor(executorAddress);
        }
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title TacStakingStorageLib
/// @notice Library for managing TAC staking executor storage in Plasma Vault
/// @dev Implements storage pattern using an isolated storage slot to maintain executor address
library TacStakingStorageLib {
    /// @dev Storage slot for TAC staking executor address
    /// @dev Calculation: keccak256(abi.encode(uint256(keccak256("io.ipor.tac.StakingExecutor")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TAC_STAKING_EXECUTOR_SLOT =
        0xd13ea098e3b10602b694749767b61b6cb8510a0a0332366961bea9fca7c66b00;

    /// @dev Structure holding the TAC staking executor address
    /// @custom:storage-location erc7201:io.ipor.tac.staking.executor
    struct TacStakingExecutorStorage {
        /// @dev The address of the TAC staking executor
        address executor;
    }

    /// @notice Gets the TAC staking executor storage pointer
    /// @return storagePtr The TacStakingExecutorStorage struct from storage
    function getTacStakingExecutorStorage() internal pure returns (TacStakingExecutorStorage storage storagePtr) {
        assembly {
            storagePtr.slot := TAC_STAKING_EXECUTOR_SLOT
        }
    }

    /// @notice Sets the TAC staking executor address
    /// @param executor The address of the TAC staking executor
    function setTacStakingExecutor(address executor) internal {
        TacStakingExecutorStorage storage storagePtr = getTacStakingExecutorStorage();
        storagePtr.executor = executor;
    }

    /// @notice Gets the TAC staking executor address
    /// @return The address of the TAC staking executor
    function getTacStakingExecutor() internal view returns (address) {
        TacStakingExecutorStorage storage storagePtr = getTacStakingExecutorStorage();
        return storagePtr.executor;
    }
}

// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title TacStakingStorageLib
/// @notice Library for managing TAC staking delegator storage in Plasma Vault
/// @dev Implements storage pattern using an isolated storage slot to maintain delegator address
library TacStakingStorageLib {
    /// @dev Storage slot for TAC staking delegator address
    /// @dev Calculation: keccak256(abi.encode(uint256(keccak256("io.ipor.tac.StakingDelegator")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant TAC_STAKING_DELEGATOR_SLOT =
        0x2c7f2e6443b388f1a6df5abedafcea539a6d91285825504444df1286873de000;

    /// @dev Structure holding the TAC staking delegator address
    /// @custom:storage-location erc7201:io.ipor.tac.StakingDelegator
    struct TacStakingDelegatorStorage {
        /// @dev The address of the TAC staking delegator
        address delegator;
    }

    /// @notice Gets the TAC staking delegator storage pointer
    /// @return storagePtr The TacStakingDelegatorStorage struct from storage
    function getTacStakingDelegatorStorage() internal pure returns (TacStakingDelegatorStorage storage storagePtr) {
        assembly {
            storagePtr.slot := TAC_STAKING_DELEGATOR_SLOT
        }
    }

    /// @notice Sets the TAC staking delegator address
    /// @param delegator The address of the TAC staking delegator
    function setTacStakingDelegator(address delegator) internal {
        TacStakingDelegatorStorage storage storagePtr = getTacStakingDelegatorStorage();
        storagePtr.delegator = delegator;
    }

    /// @notice Gets the TAC staking delegator address
    /// @return The address of the TAC staking delegator
    function getTacStakingDelegator() internal view returns (address) {
        TacStakingDelegatorStorage storage storagePtr = getTacStakingDelegatorStorage();
        return storagePtr.delegator;
    }
}

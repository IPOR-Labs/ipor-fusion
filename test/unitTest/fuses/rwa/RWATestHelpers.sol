// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

/// @title RWATestConstants
/// @notice Shared constants used by the RWA test suite (CQ-26: dedup `RWA_SLOT` from 6+ files).
library RWATestConstants {
    /// @dev Pre-computed ERC-7201 storage slot for `RWAExecutorStorageLib.RWAStorage`.
    ///      Mirrors the constant in `RWAExecutorStorageLib._RWA_STORAGE_SLOT`.
    bytes32 internal constant RWA_SLOT = 0x2c33642f9f95a2ae96c65138627f6a55480cec20290d678b3efcc2db4caa9400;

    /// @dev Offsets from the ERC-7201 base slot into `RWAStorage` fields.
    ///      Matches the struct layout in `RWAExecutorStorageLib.RWAStorage`:
    ///      [0] executor, [1] lastTotalBalance, [2] lastCheckedCustodianTimestamp, [3] paused.
    uint256 internal constant EXECUTOR_SLOT_OFFSET = 0;
    uint256 internal constant LAST_TOTAL_BALANCE_SLOT_OFFSET = 1;
    uint256 internal constant LAST_CHECKED_CUSTODIAN_TS_SLOT_OFFSET = 2;
    uint256 internal constant PAUSED_SLOT_OFFSET = 3;
}

/// @title RWASlotHelpers
/// @notice Stateless helpers for reading and writing the RWA ERC-7201 storage slots
///         (CQ-24: dedup `_setPaused` / `_readPaused` from 4 test files).
/// @dev Callers pass the vault address explicitly so the library can be used from any test
///      harness without caring about the caller's field naming.
library RWASlotHelpers {
    /// @dev Foundry cheatcode address; matches `forge-std/Vm.sol`.
    Vm private constant _VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Writes the paused flag into the given vault's RWA storage.
    /// @param vault_ The vault address whose ERC-7201 slot to update.
    /// @param value_ The new paused flag.
    function setPaused(address vault_, bool value_) internal {
        bytes32 slot = bytes32(uint256(RWATestConstants.RWA_SLOT) + RWATestConstants.PAUSED_SLOT_OFFSET);
        _VM.store(vault_, slot, bytes32(uint256(value_ ? 1 : 0)));
    }

    /// @notice Reads the paused flag from the given vault's RWA storage.
    /// @param vault_ The vault address whose ERC-7201 slot to inspect.
    /// @return Value of the paused flag.
    function readPaused(address vault_) internal view returns (bool) {
        bytes32 slot = bytes32(uint256(RWATestConstants.RWA_SLOT) + RWATestConstants.PAUSED_SLOT_OFFSET);
        return _VM.load(vault_, slot) != bytes32(0);
    }

    /// @notice Writes the executor address into the given vault's RWA storage.
    /// @param vault_ The vault address whose ERC-7201 slot to update.
    /// @param executor_ The executor address to store.
    function setExecutor(address vault_, address executor_) internal {
        bytes32 slot = bytes32(uint256(RWATestConstants.RWA_SLOT) + RWATestConstants.EXECUTOR_SLOT_OFFSET);
        _VM.store(vault_, slot, bytes32(uint256(uint160(executor_))));
    }

    /// @notice Writes `lastTotalBalance` into the given vault's RWA storage.
    /// @param vault_ The vault address whose ERC-7201 slot to update.
    /// @param value_ The new cached total balance.
    function setLastTotalBalance(address vault_, uint256 value_) internal {
        bytes32 slot = bytes32(uint256(RWATestConstants.RWA_SLOT) + RWATestConstants.LAST_TOTAL_BALANCE_SLOT_OFFSET);
        _VM.store(vault_, slot, bytes32(value_));
    }

    /// @notice Writes `lastCheckedCustodianTimestamp` into the given vault's RWA storage.
    /// @param vault_ The vault address whose ERC-7201 slot to update.
    /// @param value_ The new cached custodian timestamp.
    function setLastCheckedCustodianTimestamp(address vault_, uint256 value_) internal {
        bytes32 slot =
            bytes32(uint256(RWATestConstants.RWA_SLOT) + RWATestConstants.LAST_CHECKED_CUSTODIAN_TS_SLOT_OFFSET);
        _VM.store(vault_, slot, bytes32(value_));
    }
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

/// @title ExternalStateTestConstants
/// @notice Shared constants used by the ExternalState test suite (CQ-26: dedup `EXTERNAL_STATE_SLOT` from 6+ files).
library ExternalStateTestConstants {
    /// @dev Pre-computed ERC-7201 storage slot for `ExternalStateExecutorStorageLib.ExternalStateStorage`.
    ///      Mirrors the constant in `ExternalStateExecutorStorageLib._EXTERNAL_STATE_STORAGE_SLOT`.
    bytes32 internal constant EXTERNAL_STATE_SLOT = 0x1781023874512ec457c16827ad102f41a5c5ce1cd7ba8aa8fcd2da52541d8a00;

    /// @dev Offsets from the ERC-7201 base slot into `ExternalStateStorage` fields.
    ///      Matches the struct layout in `ExternalStateExecutorStorageLib.ExternalStateStorage`:
    ///      [0] executor, [1] lastTotalBalance, [2] lastCheckedCustodianTimestamp, [3] paused.
    uint256 internal constant EXECUTOR_SLOT_OFFSET = 0;
    uint256 internal constant LAST_TOTAL_BALANCE_SLOT_OFFSET = 1;
    uint256 internal constant LAST_CHECKED_CUSTODIAN_TS_SLOT_OFFSET = 2;
    uint256 internal constant PAUSED_SLOT_OFFSET = 3;
}

/// @title ExternalStateSlotHelpers
/// @notice Stateless helpers for reading and writing the ExternalState ERC-7201 storage slots
///         (CQ-24: dedup `_setPaused` / `_readPaused` from 4 test files).
/// @dev Callers pass the vault address explicitly so the library can be used from any test
///      harness without caring about the caller's field naming.
library ExternalStateSlotHelpers {
    /// @dev Foundry cheatcode address; matches `forge-std/Vm.sol`.
    Vm private constant _VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice Writes the paused flag into the given vault's ExternalState storage.
    /// @param vault_ The vault address whose ERC-7201 slot to update.
    /// @param value_ The new paused flag.
    function setPaused(address vault_, bool value_) internal {
        bytes32 slot = bytes32(uint256(ExternalStateTestConstants.EXTERNAL_STATE_SLOT) + ExternalStateTestConstants.PAUSED_SLOT_OFFSET);
        _VM.store(vault_, slot, bytes32(uint256(value_ ? 1 : 0)));
    }

    /// @notice Reads the paused flag from the given vault's ExternalState storage.
    /// @param vault_ The vault address whose ERC-7201 slot to inspect.
    /// @return Value of the paused flag.
    function readPaused(address vault_) internal view returns (bool) {
        bytes32 slot = bytes32(uint256(ExternalStateTestConstants.EXTERNAL_STATE_SLOT) + ExternalStateTestConstants.PAUSED_SLOT_OFFSET);
        return _VM.load(vault_, slot) != bytes32(0);
    }

    /// @notice Writes the executor address into the given vault's ExternalState storage.
    /// @param vault_ The vault address whose ERC-7201 slot to update.
    /// @param executor_ The executor address to store.
    function setExecutor(address vault_, address executor_) internal {
        bytes32 slot = bytes32(uint256(ExternalStateTestConstants.EXTERNAL_STATE_SLOT) + ExternalStateTestConstants.EXECUTOR_SLOT_OFFSET);
        _VM.store(vault_, slot, bytes32(uint256(uint160(executor_))));
    }

    /// @notice Writes `lastTotalBalance` into the given vault's ExternalState storage.
    /// @param vault_ The vault address whose ERC-7201 slot to update.
    /// @param value_ The new cached total balance.
    function setLastTotalBalance(address vault_, uint256 value_) internal {
        bytes32 slot = bytes32(uint256(ExternalStateTestConstants.EXTERNAL_STATE_SLOT) + ExternalStateTestConstants.LAST_TOTAL_BALANCE_SLOT_OFFSET);
        _VM.store(vault_, slot, bytes32(value_));
    }

    /// @notice Writes `lastCheckedCustodianTimestamp` into the given vault's ExternalState storage.
    /// @param vault_ The vault address whose ERC-7201 slot to update.
    /// @param value_ The new cached custodian timestamp.
    function setLastCheckedCustodianTimestamp(address vault_, uint256 value_) internal {
        bytes32 slot =
            bytes32(uint256(ExternalStateTestConstants.EXTERNAL_STATE_SLOT) + ExternalStateTestConstants.LAST_CHECKED_CUSTODIAN_TS_SLOT_OFFSET);
        _VM.store(vault_, slot, bytes32(value_));
    }
}

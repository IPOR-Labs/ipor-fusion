// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {PlasmaVaultStorageLib} from "../../../contracts/libraries/PlasmaVaultStorageLib.sol";
import {CrosschainVaultHarness} from "./CrosschainVaultHarness.sol";

/// @title CrosschainWatchedVaultHarness
/// @notice `CrosschainVaultHarness` that can also store pre-hook substrates the way `PreHooksLib.setPreHookImplementations`
///         does: under `keccak256(abi.encodePacked(implementation, selector))` in the pre-hooks config of the vault storage,
///         so `CrosschainNavValidationPreHook.run` (delegatecalled through `runPreHook`) reads its list of watched vaults
///         from this contract (IL-9720).
contract CrosschainWatchedVaultHarness is CrosschainVaultHarness {
    constructor(address underlying_) CrosschainVaultHarness(underlying_) {}

    function setPreHookSubstrates(address implementation_, bytes4 selector_, bytes32[] calldata substrates_) external {
        PlasmaVaultStorageLib.getPreHooksConfig().substrates[
            keccak256(abi.encodePacked(implementation_, selector_))
        ] = substrates_;
    }
}

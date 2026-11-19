// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IVaultRoleRegistry} from "./IVaultRoleRegistry.sol";

/// @title VaultRoleRegistryStorageLib
/// @notice ERC-7201 storage and index bookkeeping of the VaultRoleRegistry
/// @dev All writes are O(1). `grant`/`revoke` keep the five assignment indexes consistent. The library emits no events
/// and performs no access control or input validation other than duplicate/missing checks of its own state.
/// `grant` and `revoke` return whether the vault entered or left the vault list, so the caller can emit the lifecycle
/// events.
library VaultRoleRegistryStorageLib {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.vaultRoleRegistry.Storage")) - 1)) & ~bytes32(uint256(0xff))
    /// @dev Do not change this value !!!
    bytes32 private constant STORAGE_SLOT = 0x5ea9c53d8dbbe442286aa23917d66e3ded631a7f9848e3b653994ce3000c9e00;

    /// @notice Catalogue data of one role
    struct VaultRoleData {
        string label;
        bool active;
    }

    /// @custom:storage-location erc7201:io.ipor.vaultRoleRegistry.Storage
    struct Storage {
        /// @dev Identifiers of all defined roles
        EnumerableSet.Bytes32Set roleIds;
        /// @dev Role data by identifier
        mapping(bytes32 roleId => VaultRoleData data) roles;
        /// @dev Vaults with at least one assignment
        EnumerableSet.AddressSet vaults;
        /// @dev Accounts with at least one role on the vault
        mapping(address vault => EnumerableSet.AddressSet accounts) vaultAccounts;
        /// @dev Roles held by the account on the vault
        mapping(address vault => mapping(address account => EnumerableSet.Bytes32Set roleIds)) accountRoles;
        /// @dev Holders of the role on the vault
        mapping(address vault => mapping(bytes32 roleId => EnumerableSet.AddressSet accounts)) roleHolders;
        /// @dev Vaults on which the account holds at least one role
        mapping(address account => EnumerableSet.AddressSet vaults) accountVaults;
    }

    // ---------------------------------------------------------------- catalogue

    /// @notice Adds a role to the catalogue as active
    /// @dev Reverts with `VaultRoleAlreadyDefined` when the role exists
    function addVaultRole(bytes32 roleId_, string memory label_) internal {
        Storage storage $ = _getStorage();
        if (!$.roleIds.add(roleId_)) {
            revert IVaultRoleRegistry.VaultRoleAlreadyDefined(roleId_);
        }
        VaultRoleData storage data = $.roles[roleId_];
        data.label = label_;
        data.active = true;
    }

    /// @notice Sets the label of a defined role
    /// @dev Reverts with `UnknownVaultRole` when the role is not defined
    function setVaultRoleLabel(bytes32 roleId_, string memory label_) internal {
        Storage storage $ = _getStorage();
        if (!$.roleIds.contains(roleId_)) {
            revert IVaultRoleRegistry.UnknownVaultRole(roleId_);
        }
        $.roles[roleId_].label = label_;
    }

    /// @notice Sets the activity flag of a defined role
    /// @dev Reverts with `UnknownVaultRole` when the role is not defined
    function setVaultRoleActive(bytes32 roleId_, bool active_) internal {
        Storage storage $ = _getStorage();
        if (!$.roleIds.contains(roleId_)) {
            revert IVaultRoleRegistry.UnknownVaultRole(roleId_);
        }
        $.roles[roleId_].active = active_;
    }

    /// @notice Returns true when the role is defined
    function isVaultRoleDefined(bytes32 roleId_) internal view returns (bool) {
        return _getStorage().roleIds.contains(roleId_);
    }

    /// @notice Returns the catalogue data of a role (empty label and inactive for an unknown role)
    function getVaultRoleData(bytes32 roleId_) internal view returns (VaultRoleData memory) {
        return _getStorage().roles[roleId_];
    }

    /// @notice Returns the activity flag of a role (false for an unknown role), without copying its label
    function isVaultRoleActive(bytes32 roleId_) internal view returns (bool) {
        return _getStorage().roles[roleId_].active;
    }

    /// @notice Returns all defined role identifiers
    function getVaultRoleIds() internal view returns (bytes32[] memory) {
        return _getStorage().roleIds.values();
    }

    // ---------------------------------------------------------------- assignments

    /// @notice Records the assignment and updates all indexes
    /// @dev Reverts with `VaultRoleAlreadyGranted` when already held
    /// @return vaultAdded True when the vault was not in the vault list before and has been added by this call
    function grant(address vault_, bytes32 roleId_, address account_) internal returns (bool vaultAdded) {
        Storage storage $ = _getStorage();
        if (!$.roleHolders[vault_][roleId_].add(account_)) {
            revert IVaultRoleRegistry.VaultRoleAlreadyGranted(vault_, roleId_, account_);
        }
        $.accountRoles[vault_][account_].add(roleId_);
        $.vaultAccounts[vault_].add(account_);
        $.accountVaults[account_].add(vault_);
        vaultAdded = $.vaults.add(vault_);
    }

    /// @notice Removes the assignment and updates all indexes
    /// @dev Reverts with `VaultRoleNotGranted` when not held
    /// @return vaultRemoved True when this call removed the last assignment of the vault and the vault left the list
    function revoke(address vault_, bytes32 roleId_, address account_) internal returns (bool vaultRemoved) {
        Storage storage $ = _getStorage();
        if (!$.roleHolders[vault_][roleId_].remove(account_)) {
            revert IVaultRoleRegistry.VaultRoleNotGranted(vault_, roleId_, account_);
        }
        EnumerableSet.Bytes32Set storage held = $.accountRoles[vault_][account_];
        held.remove(roleId_);
        if (held.length() == 0) {
            $.vaultAccounts[vault_].remove(account_);
            $.accountVaults[account_].remove(vault_);
            if ($.vaultAccounts[vault_].length() == 0) {
                vaultRemoved = $.vaults.remove(vault_);
            }
        }
    }

    /// @notice Returns true when the account holds the role on the vault
    function hasVaultRole(address vault_, bytes32 roleId_, address account_) internal view returns (bool) {
        return _getStorage().roleHolders[vault_][roleId_].contains(account_);
    }

    // ---------------------------------------------------------------- set getters

    function getVaultsCount() internal view returns (uint256) {
        return _getStorage().vaults.length();
    }

    function getVaultAt(uint256 index_) internal view returns (address) {
        return _getStorage().vaults.at(index_);
    }

    function getVaults() internal view returns (address[] memory) {
        return _getStorage().vaults.values();
    }

    function getVaultAccountsCount(address vault_) internal view returns (uint256) {
        return _getStorage().vaultAccounts[vault_].length();
    }

    function getVaultAccountAt(address vault_, uint256 index_) internal view returns (address) {
        return _getStorage().vaultAccounts[vault_].at(index_);
    }

    function getAccountRoles(address vault_, address account_) internal view returns (bytes32[] memory) {
        return _getStorage().accountRoles[vault_][account_].values();
    }

    function getRoleHolders(address vault_, bytes32 roleId_) internal view returns (address[] memory) {
        return _getStorage().roleHolders[vault_][roleId_].values();
    }

    function getRoleHoldersCount(address vault_, bytes32 roleId_) internal view returns (uint256) {
        return _getStorage().roleHolders[vault_][roleId_].length();
    }

    function getRoleHolderAt(address vault_, bytes32 roleId_, uint256 index_) internal view returns (address) {
        return _getStorage().roleHolders[vault_][roleId_].at(index_);
    }

    function getAccountVaultsCount(address account_) internal view returns (uint256) {
        return _getStorage().accountVaults[account_].length();
    }

    function getAccountVaultAt(address account_, uint256 index_) internal view returns (address) {
        return _getStorage().accountVaults[account_].at(index_);
    }

    function getAccountVaults(address account_) internal view returns (address[] memory) {
        return _getStorage().accountVaults[account_].values();
    }

    function _getStorage() private pure returns (Storage storage $) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            $.slot := STORAGE_SLOT
        }
    }
}

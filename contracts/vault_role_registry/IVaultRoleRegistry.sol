// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

// solhint-disable gas-indexed-events
// IPOR Fusion convention: event parameters are never `indexed`, all values are kept in the data section.

/// @notice Definition of a role in the registry catalogue
/// @param roleId Unique, non-zero identifier of the role
/// @param label Human readable label, 1..64 bytes
/// @param active True when the role can be granted; deactivation never removes existing assignments
struct VaultRoleDefinition {
    bytes32 roleId;
    string label;
    bool active;
}

/// @notice Roles held by one account on one vault
/// @param account The account holding the roles
/// @param roleIds Identifiers of the roles held by the account on the vault
struct AccountRoles {
    address account;
    bytes32[] roleIds;
}

/**
 * @title IVaultRoleRegistry
 * @author IPOR Labs
 * @notice Registry in which the atomist of a Plasma Vault assigns informational roles (e.g. Risk Manager, Risk
 * Monitor, Brand Manager) to accounts, per vault. The registry grants no on-chain permissions; it is a source of truth
 * for off-chain consumers. Views return assignments as stored, without filtering by the `active` flag of the role.
 * @dev Enumeration order of the vault and account sets (`getVaults*`, `getAccountVaults*`, `getVaultAccountsWithRoles*`,
 * `getAccountRoles`, `getRoleHolders`) is not stable (swap-and-pop removal). The role catalogue only grows, so
 * `getVaultRoles` keeps insertion order (seeded roles first). Assignment views are raw: they also list assignments of
 * deactivated roles, so a consumer that authorizes access must check `active` of the role (`getVaultRoles` /
 * `getVaultRole`). Atomist write functions (`grantVaultRole(s)`, `revokeVaultRole(s)`) call `authority()` on the
 * vault; a vault address without code, or without `authority()`, reverts with empty data. `removeVault` never calls
 * the vault. Vault lifecycle: a vault enters the vault list with its first assignment (`VaultAdded`, right after the
 * causing `VaultRoleGranted`) and leaves it when its last assignment is revoked, by the atomist or by `removeVault`
 * (`VaultRemoved`, right after the causing `VaultRoleRevoked`).
 */
interface IVaultRoleRegistry {
    /// @notice Emitted when a role is added to the catalogue
    /// @param roleId The new role identifier
    /// @param label The label of the role
    /// @param sender The account that added the role
    event VaultRoleAdded(bytes32 roleId, string label, address sender);

    /// @notice Emitted when the label of a role is changed
    /// @param roleId The role identifier
    /// @param label The new label
    /// @param sender The account that changed the label
    event VaultRoleLabelUpdated(bytes32 roleId, string label, address sender);

    /// @notice Emitted when a role is activated or deactivated
    /// @param roleId The role identifier
    /// @param active The new activity flag
    /// @param sender The account that changed the flag
    event VaultRoleActiveUpdated(bytes32 roleId, bool active, address sender);

    /// @notice Emitted when a role is granted to an account on a vault
    /// @param vault The Plasma Vault
    /// @param roleId The role identifier
    /// @param account The account receiving the role
    /// @param sender The account that granted the role (the atomist of the vault)
    event VaultRoleGranted(address vault, bytes32 roleId, address account, address sender);

    /// @notice Emitted when a role is revoked from an account on a vault
    /// @param vault The Plasma Vault
    /// @param roleId The role identifier
    /// @param account The account losing the role
    /// @param sender The account that revoked the role (the atomist of the vault, or the remover in `removeVault`)
    event VaultRoleRevoked(address vault, bytes32 roleId, address account, address sender);

    /// @notice Emitted when a vault enters the vault list, i.e. on its first assignment (again after a `VaultRemoved`)
    /// @dev Emitted right after the `VaultRoleGranted` that caused it, also inside a batch grant.
    /// @param vault The Plasma Vault
    /// @param sender The account that made the first assignment
    event VaultAdded(address vault, address sender);

    /// @notice Emitted when a vault leaves the vault list, i.e. when its last assignment is gone
    /// @dev Emitted right after the `VaultRoleRevoked` that caused it, on the atomist path and in `removeVault`.
    /// @param vault The Plasma Vault
    /// @param sender The account that removed the last assignment
    event VaultRemoved(address vault, address sender);

    /// @notice Caller is not an atomist of the vault
    /// @param vault The Plasma Vault
    /// @param caller The rejected caller
    error CallerNotVaultAtomist(address vault, address caller);

    /// @notice The vault returned the zero address from `authority()`, so it has no access manager
    /// @param vault The Plasma Vault
    error NoAccessManager(address vault);

    /// @notice The role is not in the catalogue
    /// @param roleId The unknown role identifier
    error UnknownVaultRole(bytes32 roleId);

    /// @notice The role is deactivated and cannot be granted
    /// @param roleId The inactive role identifier
    error VaultRoleInactive(bytes32 roleId);

    /// @notice The role is already in the catalogue
    /// @param roleId The duplicated role identifier
    error VaultRoleAlreadyDefined(bytes32 roleId);

    /// @notice The role identifier is zero
    error InvalidVaultRoleId();

    /// @notice The label is empty or longer than 64 bytes
    error InvalidVaultRoleLabel();

    /// @notice The account already holds the role on the vault
    /// @param vault The Plasma Vault
    /// @param roleId The role identifier
    /// @param account The account
    error VaultRoleAlreadyGranted(address vault, bytes32 roleId, address account);

    /// @notice The account does not hold the role on the vault
    /// @param vault The Plasma Vault
    /// @param roleId The role identifier
    /// @param account The account
    error VaultRoleNotGranted(address vault, bytes32 roleId, address account);

    /// @notice The vault has no assignments in the registry
    /// @param vault The Plasma Vault
    error VaultNotRegistered(address vault);

    // ---------------------------------------------------------------- catalogue writes

    /// @notice Adds a role to the catalogue; the new role is active
    /// @param roleId_ Non-zero role identifier, not yet defined
    /// @param label_ Label, 1..64 bytes
    function addVaultRole(bytes32 roleId_, string calldata label_) external;

    /// @notice Changes the label of a defined role
    /// @param roleId_ Defined role identifier
    /// @param label_ New label, 1..64 bytes
    function updateVaultRoleLabel(bytes32 roleId_, string calldata label_) external;

    /// @notice Activates or deactivates a defined role; existing assignments are kept
    /// @param roleId_ Defined role identifier
    /// @param active_ New activity flag
    function setVaultRoleActive(bytes32 roleId_, bool active_) external;

    // ---------------------------------------------------------------- assignment writes (vault atomist only)

    /// @notice Grants an active role to an account on a vault
    /// @param vault_ The Plasma Vault
    /// @param roleId_ Active role identifier
    /// @param account_ Non-zero account
    function grantVaultRole(address vault_, bytes32 roleId_, address account_) external;

    /// @notice Revokes a role from an account on a vault (allowed also for inactive roles)
    /// @param vault_ The Plasma Vault
    /// @param roleId_ Defined role identifier
    /// @param account_ The account
    function revokeVaultRole(address vault_, bytes32 roleId_, address account_) external;

    /// @notice Grants many roles; entries are paired by index
    /// @dev Atomic: any failing entry reverts the whole call. Check order: empty or mismatched arrays
    /// (`Errors.WrongArrayLength`), zero vault (`Errors.WrongAddress`), atomist check once (`NoAccessManager`,
    /// `CallerNotVaultAtomist`), then per entry: zero account (`Errors.WrongAddress`), `UnknownVaultRole`,
    /// `VaultRoleInactive`, `VaultRoleAlreadyGranted` (also for a duplicate entry within the batch).
    /// @param vault_ The Plasma Vault
    /// @param roleIds_ Role identifiers
    /// @param accounts_ Accounts, same length as `roleIds_`
    function grantVaultRoles(address vault_, bytes32[] calldata roleIds_, address[] calldata accounts_) external;

    /// @notice Revokes many roles; entries are paired by index
    /// @dev Atomic: any failing entry reverts the whole call. Check order: empty or mismatched arrays
    /// (`Errors.WrongArrayLength`), zero vault (`Errors.WrongAddress`), atomist check once (`NoAccessManager`,
    /// `CallerNotVaultAtomist`), then per entry: zero account (`Errors.WrongAddress`), `UnknownVaultRole`,
    /// `VaultRoleNotGranted` (also for a duplicate entry within the batch). Revoking inactive roles is allowed.
    /// @param vault_ The Plasma Vault
    /// @param roleIds_ Role identifiers
    /// @param accounts_ Accounts, same length as `roleIds_`
    function revokeVaultRoles(address vault_, bytes32[] calldata roleIds_, address[] calldata accounts_) external;

    // ---------------------------------------------------------------- vault removal (VAULT_REMOVER_ROLE only)

    /// @notice Revokes every role of up to `maxAccounts_` accounts of a vault; the vault leaves the list with its last
    /// account
    /// @dev Callable only by a holder of `VAULT_REMOVER_ROLE`. Never calls the vault (no `authority()`), so it also
    /// clears vaults without code or with a reverting `authority()`. Check order: role
    /// (`AccessControlUnauthorizedAccount`), zero vault (`Errors.WrongAddress`), `maxAccounts_ == 0`
    /// (`Errors.WrongValue`), vault without accounts (`VaultNotRegistered`). Accounts are removed from the end of the
    /// account set of the vault, so the remaining prefix keeps its order. Every role of a removed account is revoked,
    /// including roles that are inactive now, emitting `VaultRoleRevoked(vault, roleId, account, msg.sender)` per
    /// assignment; `VaultRemoved` is emitted once, when the last account is gone. A partially cleared vault is a
    /// regular vault with fewer accounts; call again to continue. Gas grows with the number of roles held by the
    /// removed accounts; `maxAccounts_` bounds accounts, not assignments, so an account holding very many catalogue
    /// roles cannot be made cheaper by lowering `maxAccounts_`.
    /// @param vault_ The Plasma Vault, non-zero
    /// @param maxAccounts_ Maximum number of accounts to clear in this call, non-zero
    /// @return remaining Number of accounts of the vault still holding roles after the call
    function removeVault(address vault_, uint256 maxAccounts_) external returns (uint256 remaining);

    // ---------------------------------------------------------------- views

    /// @notice Returns the whole role catalogue
    /// @return The role definitions in insertion order, including inactive roles
    function getVaultRoles() external view returns (VaultRoleDefinition[] memory);

    /// @notice Returns one role definition; reverts with `UnknownVaultRole` for an unknown id
    /// @param roleId_ Role identifier
    /// @return The definition of the role
    function getVaultRole(bytes32 roleId_) external view returns (VaultRoleDefinition memory);

    /// @notice Returns true when the role is in the catalogue
    /// @param roleId_ Role identifier
    /// @return True when the role is in the catalogue
    function isVaultRoleDefined(bytes32 roleId_) external view returns (bool);

    /// @notice Returns all vaults that have at least one assignment
    /// @dev Unbounded: anyone can add fake vaults (a vault whose `authority()` names the caller as atomist), so the
    /// call can be inflated until it exceeds the `eth_call` gas cap. Backends must use `getVaultsPaginated`.
    /// @return All vaults with at least one assignment, in unstable order
    function getVaults() external view returns (address[] memory);

    /// @notice Returns the number of vaults that have at least one assignment
    /// @return The number of vaults
    function getVaultsCount() external view returns (uint256);

    /// @notice Returns a page of vaults that have at least one assignment
    /// @dev Order is not stable (swap-and-pop) and `offset_` is not a persistent cursor: a complete snapshot requires
    /// reading all pages at the same block number/hash. `offset_ >= count` or `limit_ == 0` returns an empty array,
    /// otherwise `min(limit_, count - offset_)` items.
    /// @param offset_ Index of the first item
    /// @param limit_ Maximum number of items
    /// @return The requested page of vaults
    function getVaultsPaginated(uint256 offset_, uint256 limit_) external view returns (address[] memory);

    /// @notice Returns all accounts holding any role on the vault, with their roles
    /// @dev Raw: includes assignments of inactive roles; consumers authorizing access must check `active`.
    /// Unbounded: anyone can register fake accounts on a fake vault, so the call can be inflated until it exceeds the
    /// `eth_call` gas cap. Backends must use `getVaultAccountsCount` and `getVaultAccountsWithRolesPaginated`.
    /// @param vault_ The Plasma Vault
    /// @return Every account of the vault with its role ids
    function getVaultAccountsWithRoles(address vault_) external view returns (AccountRoles[] memory);

    /// @notice Returns the number of accounts holding any role on the vault
    /// @dev Zero for a vault that is not in the registry. In one block it equals the length of
    /// `getVaultAccountsWithRoles`.
    /// @param vault_ The Plasma Vault
    /// @return The number of accounts with at least one role on the vault
    function getVaultAccountsCount(address vault_) external view returns (uint256);

    /// @notice Returns a page of the accounts holding any role on the vault, with their roles
    /// @dev Same set and same order as `getVaultAccountsWithRoles`. Order is the order of first assignment until the
    /// first removal: removing the account at index `i` moves the last account to `i`, removing the last account moves
    /// nothing, and `removeVault` removes from the end, so the remaining prefix keeps its order. Within one block
    /// `getVaultAccountsCount` equals the length of the full list and the concatenation of the pages equals the full
    /// list. Order is otherwise not stable (swap-and-pop) and `offset_` is not a persistent cursor across blocks: a
    /// complete snapshot requires reading the count and all pages at the same block number/hash. `offset_ >= count` or `limit_ == 0` returns an empty array, otherwise
    /// `min(limit_, count - offset_)` items. Raw: includes assignments of inactive roles; `roleIds` of an entry grows
    /// with the catalogue.
    /// @param vault_ The Plasma Vault
    /// @param offset_ Index of the first item
    /// @param limit_ Maximum number of items
    /// @return The requested page of accounts with their role ids
    function getVaultAccountsWithRolesPaginated(
        address vault_,
        uint256 offset_,
        uint256 limit_
    ) external view returns (AccountRoles[] memory);

    /// @notice Returns the roles held by the account on the vault
    /// @dev Raw: includes inactive roles; consumers authorizing access must check `active`.
    /// @param vault_ The Plasma Vault
    /// @param account_ The account
    /// @return The role ids held by the account on the vault
    function getAccountRoles(address vault_, address account_) external view returns (bytes32[] memory);

    /// @notice Returns the accounts holding the role on the vault
    /// @dev Raw: also returns holders of an inactive role; consumers authorizing access must check `active`.
    /// Unbounded: anyone can register fake accounts under a fake vault, so the call can be inflated until it exceeds the
    /// `eth_call` gas cap. Backends must use `getRoleHoldersCount` and `getRoleHoldersPaginated` (or `hasVaultRole`).
    /// @param vault_ The Plasma Vault
    /// @param roleId_ Role identifier
    /// @return The accounts holding the role
    function getRoleHolders(address vault_, bytes32 roleId_) external view returns (address[] memory);

    /// @notice Returns the number of accounts holding the role on the vault
    /// @dev Zero for an unknown vault or role. In one block it equals the length of `getRoleHolders`.
    /// @param vault_ The Plasma Vault
    /// @param roleId_ Role identifier
    /// @return The number of holders of the role on the vault
    function getRoleHoldersCount(address vault_, bytes32 roleId_) external view returns (uint256);

    /// @notice Returns a page of the accounts holding the role on the vault
    /// @dev Same set and same order as `getRoleHolders`. Within one block `getRoleHoldersCount` equals the length of
    /// the full list and the concatenation of the pages equals the full list. Order is otherwise not stable
    /// (swap-and-pop on removal) and `offset_` is not a persistent cursor across blocks: a complete snapshot requires
    /// reading the count and all pages at the same block number/hash. `offset_ >= count` or `limit_ == 0` returns an
    /// empty array, otherwise `min(limit_, count - offset_)` items. Raw: also returns holders of an inactive role;
    /// consumers authorizing access must check `active`.
    /// @param vault_ The Plasma Vault
    /// @param roleId_ Role identifier
    /// @param offset_ Index of the first item
    /// @param limit_ Maximum number of items
    /// @return page The requested page of holders
    function getRoleHoldersPaginated(
        address vault_,
        bytes32 roleId_,
        uint256 offset_,
        uint256 limit_
    ) external view returns (address[] memory page);

    /// @notice Returns true when the account holds the role on the vault
    /// @dev Raw: true also for an inactive role; consumers authorizing access must check `active`.
    /// @param vault_ The Plasma Vault
    /// @param roleId_ Role identifier
    /// @param account_ The account
    /// @return True when the assignment exists
    function hasVaultRole(address vault_, bytes32 roleId_, address account_) external view returns (bool);

    /// @notice Returns all vaults on which the account holds any role
    /// @dev Unbounded: anyone can add fake vaults that list `account_` (even a victim account), so the call can be
    /// inflated until it exceeds the `eth_call` gas cap. Backends must use `getAccountVaultsPaginated`.
    /// @param account_ The account
    /// @return All vaults on which the account holds any role, in unstable order
    function getAccountVaults(address account_) external view returns (address[] memory);

    /// @notice Returns the number of vaults on which the account holds any role
    /// @param account_ The account
    /// @return The number of vaults
    function getAccountVaultsCount(address account_) external view returns (uint256);

    /// @notice Returns a page of vaults on which the account holds any role
    /// @dev Order is not stable (swap-and-pop) and `offset_` is not a persistent cursor: a complete snapshot requires
    /// reading all pages at the same block number/hash. `offset_ >= count` or `limit_ == 0` returns an empty array,
    /// otherwise `min(limit_, count - offset_)` items.
    /// @param account_ The account
    /// @param offset_ Index of the first item
    /// @param limit_ Maximum number of items
    /// @return The requested page of vaults
    function getAccountVaultsPaginated(
        address account_,
        uint256 offset_,
        uint256 limit_
    ) external view returns (address[] memory);
}

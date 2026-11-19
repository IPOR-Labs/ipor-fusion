# VaultRoleRegistry

## Overview

`VaultRoleRegistry` is a per-chain registry in which the **atomist of a Plasma Vault** assigns off-chain roles
(Risk Manager, Risk Monitor, Brand Manager, more can be added later) to addresses, per vault.

- **One registry per chain.**
- **Informational only.** The backend (IL-9489) reads the registry to authorize Dashboard, Monitoring and Settings API
  access. Fusion contracts never read or enforce these roles; the registry grants no on-chain permissions.
- **Upgradeable.** UUPS implementation behind `ERC1967Proxy`, `initialize(admin)`; same management model as
  `PriceOracleMiddlewareWithRoles`.

**Location:** `contracts/vault_role_registry/`

| File                                 | Purpose                                                                                                   |
| ------------------------------------ | --------------------------------------------------------------------------------------------------------- |
| `VaultRoleRegistry.sol`              | The contract (UUPS)                                                                                       |
| `IVaultRoleRegistry.sol`             | External API, events, custom errors, `VaultRoleDefinition` / `AccountRoles` structs                       |
| `VaultRoleRegistryAccessControl.sol` | `AccessControlEnumerableUpgradeable` base, defines `ROLES_CATALOG_MANAGER_ROLE` and `VAULT_REMOVER_ROLE`  |
| `VaultRoleRegistryStorageLib.sol`    | ERC-7201 storage `erc7201:io.ipor.vaultRoleRegistry.Storage`, enumerable sets and forward/reverse indexes |

## Trust Model

| Actor                                                                | Powers                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `DEFAULT_ADMIN_ROLE` (must be the IPOR multisig)                     | Grants and revokes `ROLES_CATALOG_MANAGER_ROLE` and any other role; alone authorizes upgrades (`_authorizeUpgrade`). Through an upgrade it can do anything.                                                                                                                                                                                                                                                                                                                                                        |
| `ROLES_CATALOG_MANAGER_ROLE`                                         | Alone adds roles to the catalogue, changes labels, activates/deactivates roles. `initialize` does **not** grant it; the admin has to grant it explicitly.                                                                                                                                                                                                                                                                                                                                                          |
| `VAULT_REMOVER_ROLE`                                                 | `removeVault` only: removes any vault (all its assignments) at its own discretion, without consulting the vault's `authority()`. It cannot remove single assignments. Removal is batched from the end of the vault's account list, so the holder can also stop early, i.e. remove the last k accounts of a live vault (each with all its roles; e.g. `removeVault(v, 1)` leaves the vault registered); the atomist can grant them again. `initialize` does **not** grant it; the admin has to grant it explicitly. |
| Vault atomist (`ATOMIST_ROLE` = `100` in the vault's access manager) | `grantVaultRole(s)` / `revokeVaultRole(s)` for that vault only.                                                                                                                                                                                                                                                                                                                                                                                                                                                    |

### How the atomist is verified

`IAccessManaged(vault).authority()` is read, then `IAccessManager(authority).hasRole(ATOMIST_ROLE, msg.sender)`.

- **There is no allowlist of vaults.** Any address whose `authority()` says the caller is an atomist is accepted.
  Anyone can therefore deploy a fake "vault" that makes them atomist, or list someone else's address under their own
  vault. Writes are O(1) per entry, so the effect is read spam, but it can reach any account: fake vaults can be
  listed under a victim account, which makes the non-paginated `getVaults` / `getAccountVaults` unbounded (about 22k
  entries can exceed a default 50M-gas `eth_call`; cheap on L2s).
- **The backend must intersect registry results with its own list of IPOR vaults** (see Backend note).
- The **execution delay** on `ATOMIST_ROLE` is ignored; membership alone decides. A **grant delay** is respected
  (`hasRole` reports non-membership until the grant is effective).
- Changing the atomist of a vault **does not clear** existing assignments. The new atomist can revoke them, and so can
  the `VAULT_REMOVER_ROLE` holder (`removeVault`), which also works for a vault whose `authority()` no longer answers.

## Role catalogue

- A role id is `bytes32 = keccak256("<NAME>")`, identical on every chain. Zero is invalid (`InvalidVaultRoleId`).
- `initialize` seeds three roles (all active):

| Constant                   | Id (`keccak256`)  | Label           |
| -------------------------- | ----------------- | --------------- |
| `VAULT_ROLE_RISK_MANAGER`  | `"RISK_MANAGER"`  | "Risk Manager"  |
| `VAULT_ROLE_RISK_MONITOR`  | `"RISK_MONITOR"`  | "Risk Monitor"  |
| `VAULT_ROLE_BRAND_MANAGER` | `"BRAND_MANAGER"` | "Brand Manager" |

- A label is 1..64 bytes (`InvalidVaultRoleLabel` otherwise).
- **No hard delete.** Deactivation (`setVaultRoleActive(roleId, false)`): an inactive role cannot be granted
  (`VaultRoleInactive`), existing assignments stay and **can still be revoked**, and views show `active = false`.
  Assignment views (`getAccountRoles`, `getRoleHolders`, `hasVaultRole`, `getVaultAccountsWithRoles`) are **raw**: they
  also return assignments of inactive roles. **Access stops when a role is deactivated** (IL-9488 D-014): the backend
  honours an assignment only while the role's `active` flag is true.
- The role catalogue only grows, so `getVaultRoles` keeps insertion order (seeded roles first).
- Labels are for humans. **The backend must map permissions by role id, never by label.**

Catalogue writes (`ROLES_CATALOG_MANAGER_ROLE`): `addVaultRole(roleId, label)` (`VaultRoleAlreadyDefined` for a
duplicate), `updateVaultRoleLabel(roleId, label)`, `setVaultRoleActive(roleId, active)` (`UnknownVaultRole` for an
undefined id). Events: `VaultRoleAdded`, `VaultRoleLabelUpdated`, `VaultRoleActiveUpdated`.

## Vault lifecycle

- A vault is on the list (`getVaults`) if and only if at least one account holds at least one role on it. There is no
  explicit "create vault" or "delete vault" state.
- `VaultAdded(vault, sender)` is emitted once each time the vault enters the list (its first assignment, or the first one after a
  `VaultRemoved`; also inside a batch), right after the `VaultRoleGranted` event that caused it.
- `VaultRemoved(vault, sender)` is emitted exactly once, when the vault leaves the list: right after the last
  `VaultRoleRevoked` of the atomist (single or batch), or inside `removeVault` when the last account is removed. A
  partial `removeVault` does not emit it.
- `VaultRoleRevoked.sender` is the atomist on the atomist path and the **remover** on the `removeVault` path.
- A removed vault can be added again; it starts clean (views equal a fresh registration, listed once).

## Atomist API

| Function                                         | Notes                                      |
| ------------------------------------------------ | ------------------------------------------ |
| `grantVaultRole(vault, roleId, account)`         | Single grant                               |
| `revokeVaultRole(vault, roleId, account)`        | Single revoke (allowed for inactive roles) |
| `grantVaultRoles(vault, roleIds[], accounts[])`  | Batch, paired by index                     |
| `revokeVaultRoles(vault, roleIds[], accounts[])` | Batch, paired by index                     |

### Check order and errors

Every **atomist** write calls `authority()` on the vault after the input checks below: a vault address without code, or without `authority()`, reverts
with empty data (no custom error).

Single calls:

1. `vault == 0` or `account == 0` - `Errors.WrongAddress`
2. Caller is not an atomist - `NoAccessManager(vault)` when `authority()` is zero, otherwise
   `CallerNotVaultAtomist(vault, caller)`
3. Role not in the catalogue - `UnknownVaultRole(roleId)`
4. Grant only: role inactive - `VaultRoleInactive(roleId)`
5. Grant: assignment already exists - `VaultRoleAlreadyGranted(vault, roleId, account)`;
   revoke: assignment missing - `VaultRoleNotGranted(vault, roleId, account)`

Batch calls: empty or mismatched arrays - `Errors.WrongArrayLength`; then `vault == 0` - `Errors.WrongAddress`;
then the atomist check (once); then per entry (in order) `account == 0` - `Errors.WrongAddress` followed by steps 3-5.
A batch is **atomic**: any failing entry reverts the whole call, so duplicate entries in one grant batch revert with
`VaultRoleAlreadyGranted` and in one revoke batch with `VaultRoleNotGranted`.

Events: `VaultRoleGranted(vault, roleId, account, sender)` and `VaultRoleRevoked(vault, roleId, account, sender)`
(the parameter was named `atomist` before; signature and topic are unchanged), plus `VaultAdded` / `VaultRemoved` as
described in [Vault lifecycle](#vault-lifecycle). Per IPOR convention no parameter is `indexed`; filter by decoding
event data.

## Remover API

`removeVault(vault, maxAccounts) returns (remaining)` - callable only by a holder of `VAULT_REMOVER_ROLE`. The admin
without the role, the atomist and the catalogue manager cannot call it (`AccessControlUnauthorizedAccount`). The admin
grants and revokes the role with the ordinary `grantRole` / `revokeRole`; the role is enumerable.

Check order:

1. Caller lacks the role - `AccessControlUnauthorizedAccount(caller, role)`
2. `vault == 0` - `Errors.WrongAddress`
3. `maxAccounts == 0` - `Errors.WrongValue`
4. The vault has no accounts (not on the list) - `VaultNotRegistered(vault)`

Behaviour:

- Removes up to `maxAccounts` accounts **from the end** of the vault's account list, each with **all** of its roles
  (including roles deactivated since), and returns the number of accounts still left. Call it again until
  `remaining == 0`; a further call then reverts `VaultNotRegistered`.
- Because accounts are taken from the end, the remaining prefix keeps its order. After a partial removal the vault is
  still listed; there is no "being removed" flag, and the atomist may add accounts between calls (the next call simply
  continues).
- Events: `VaultRoleRevoked(vault, roleId, account, remover)` per removed assignment, then `VaultRemoved(vault, remover)`
  once when the last account is gone.
- It does not call `authority()` or anything else on the vault, so it works for a vault without code or with a reverting
  `authority()`, where the atomist path reverts.

### Choosing `maxAccounts` (gas)

`maxAccounts` bounds **accounts, not assignments**. The cost of one account grows with the number of roles it holds,
and the role catalogue has no hard cap, so the guidance below is conditional.

Measured cold (one transaction per call, forge 1.9.0, EVM cancun; 10 accounts per vault removed in a single
`removeVault(vault, 10)`; gas counted inside the call, so the 21k intrinsic cost and calldata are **excluded**):

| Roles per removed account | Gas per account |
| ------------------------- | --------------- |
| 1                         | about 64k       |
| 3                         | about 117k      |

That is roughly 26.5k per additional role. Example for accounts holding 3 roles each: a budget of 10M gas per call
allows about 85 accounts (10M / 117k); a step of **50** accounts (about 5.9M gas) leaves a safety margin of roughly
40%. Recompute the example if the roles per account grow (the measurement covers 1 and 3 roles only).

- Too large a step runs out of gas and reverts without any state change; retry with a smaller step.
- Lowering `maxAccounts` **cannot** make a single account with very many roles cheaper: `maxAccounts = 1` still removes
  all roles of that account in one call.
- The catalogue only grows and today has three roles. Keeping it small is an **operational constraint on
  `ROLES_CATALOG_MANAGER_ROLE`** (a trusted role); if the catalogue is ever expected to reach dozens of roles, a
  per-assignment limit would need a follow-up change.
- The same growth makes the `roleIds` array of every `getVaultAccountsWithRoles*` entry grow with the catalogue.

## Views

| View                                                                                                               | Returns                                                                                                  |
| ------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------- |
| `getVaultRoles()` / `getVaultRole(roleId)`                                                                         | Catalogue (`roleId`, `label`, `active`); `getVaultRole` reverts `UnknownVaultRole`                       |
| `isVaultRoleDefined(roleId)`                                                                                       | Whether the role is in the catalogue                                                                     |
| `getVaults()`, `getVaultsCount()`, `getVaultsPaginated(offset, limit)`                                             | Vaults with at least one assignment                                                                      |
| `getVaultAccountsWithRoles(vault)`                                                                                 | Every account of the vault with its role ids (`AccountRoles[]`); **unbounded**, see below                |
| `getVaultAccountsCount(vault)`                                                                                     | Number of accounts holding at least one role on the vault; `0` for a vault not in the registry           |
| `getVaultAccountsWithRolesPaginated(vault, offset, limit)`                                                         | Page of the same list, same order and same entries as `getVaultAccountsWithRoles`                        |
| `getAccountRoles(vault, account)`                                                                                  | Role ids held by the account on the vault                                                                |
| `getRoleHolders(vault, roleId)`                                                                                    | Accounts holding the role on the vault; **unbounded**, see below                                         |
| `getRoleHoldersCount(vault, roleId)`                                                                               | Number of holders of the role on the vault; `0` for an unknown vault or role                             |
| `getRoleHoldersPaginated(vault, roleId, offset, limit)`                                                            | Page of the same list, same order as `getRoleHolders` (raw: inactive roles included)                     |
| `hasVaultRole(vault, roleId, account)`                                                                             | Boolean                                                                                                  |
| `getAccountVaults(account)`, `getAccountVaultsCount(account)`, `getAccountVaultsPaginated(account, offset, limit)` | Reverse index: vaults on which the account holds any role (e.g. "a Risk Manager sees only their vaults") |

### Pagination and same-block reads

- `offset >= count` or `limit == 0` returns an empty array; otherwise `min(limit, count - offset)` items.
- **Enumeration order of vault/account sets is not stable** (removal is swap-and-pop). The role catalogue keeps
  insertion order.
- **Order promise for vault accounts.** Within one block, `getVaultAccountsCount(vault)` equals
  `getVaultAccountsWithRoles(vault).length`, and the concatenation of the pages of `getVaultAccountsWithRolesPaginated`
  equals the full list element by element (account and `roleIds`). The order is the order of **first assignment until
  the first removal**; removing the account at position `i` moves the **last** account to position `i` (swap-and-pop),
  removing the last account moves nothing. `removeVault` removes from the end, so the remaining prefix keeps its order.
- **`offset` is not a cursor across blocks.** A removal between two page reads can move an entry into an already read
  position and it will be skipped. **Read all pages at the same block number/hash** (`eth_call` with a block tag),
  and always use the paginated views. For vault accounts, read the count and all pages in **one** Multicall3
  `aggregate` call (one `eth_call` is one block) or with one shared block tag.
- **Never call `getVaults()` / `getAccountVaults(account)` from the backend.** They are unbounded and anyone can inflate
  them with fake vaults, including for a victim account.
- **Never call `getVaultAccountsWithRoles(vault)` from the backend for untrusted vaults.** It is unbounded as well (the
  atomist of a fake vault can list any number of accounts); use `getVaultAccountsCount` and the paginated view.
- **Never call `getRoleHolders(vault, roleId)` from the backend for untrusted vaults.** It is unbounded as well (the
  atomist of a fake vault can register any number of holders of one role); use `getRoleHoldersCount` plus all pages of
  `getRoleHoldersPaginated` read at one block (same rule as for the per-vault accounts), or `hasVaultRole`. Within one
  block the count equals `getRoleHolders(vault, roleId).length` and the pages concatenate to the full list.

## Deploy runbook

Deploy and `ipor-abi` registration are outside the IL-9488 code change.

1. On every launch chain, deploy the `VaultRoleRegistry` implementation and an
   `ERC1967Proxy(implementation, initialize(multisig))` via a migration in `ipor-protocol-deploy` (pattern of
   `017_deploy_price_oracle_middleware_with_roles`). `multisig` is the IPOR multisig and receives `DEFAULT_ADMIN_ROLE`.
2. If catalogue changes are needed, the multisig grants `ROLES_CATALOG_MANAGER_ROLE` to the intended account.
   If vault cleanup is wanted, the multisig grants `VAULT_REMOVER_ROLE` to the operations account (`initialize` does
   not grant it).
3. Add the proxy address to `ipor-abi`.
4. Verify: `getVaultRoles()` returns the three seeded roles; `hasRole(DEFAULT_ADMIN_ROLE, multisig)` is true.

## Backend note (IL-9489)

1. **Intersect registry results with your own list of IPOR vaults** - the registry accepts any vault whose authority
   names the caller as atomist.
2. **Map permissions by role id, never by label.**
3. **Read all pages at one block** (number or hash) when using paginated views. Use only the paginated views for vault
   and account-vault enumeration, and authorize per vault from your own vault list (`getAccountRoles(vault, account)`
   per IPOR vault), not from `getAccountVaults(account)` of an untrusted result.
4. **Honour an assignment only while its role is active** (IL-9488 D-014). Views are raw; join them with
   `getVaultRoles()` (or `getVaultRole(roleId).active`) and drop assignments of inactive roles. Re-activating a role
   restores the access of the assignments that were kept.
5. **Read the accounts of a vault consistently.** Use `getVaultAccountsCount` plus all pages of
   `getVaultAccountsWithRolesPaginated` in one Multicall3 `aggregate` call (or with one block tag). If the count changes
   or a vault event arrives while you are reading, read again. Deduplicate by address, and do not treat an account that
   is missing from an inconsistent set of pages as revoked.
6. **Handle the new events.** On `VaultRemoved` drop all grants of that vault. `VaultRoleRevoked` can now come from the
   remover (`sender` is not the atomist); do not assume the sender is an atomist. `VaultAdded` marks each entry
   of a vault into the list (its first assignment, or the first one after a `VaultRemoved`). The event parameter `atomist` was renamed `sender` (topics unchanged; decode by position).

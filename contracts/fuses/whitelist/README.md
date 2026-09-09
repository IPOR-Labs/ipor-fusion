# Fuse Whitelist

## Overview

`contracts/fuses/whitelist/` is **not a fuse**. `FuseWhitelist` is a standalone, upgradeable
(UUPS) registry that IPOR Labs uses to publish which fuse contracts are known, of what type, in
what state, and with which metadata, grouped by the `MARKET_ID` the fuse reports. Plasma Vaults
do not consult it on chain; tooling and operators do. It has no `enter`/`exit`, no market of its
own and no balance, so it has no entry in `catalog/fuses.json`.

## Components

- **`FuseWhitelist`** — the upgradeable contract: add/update entries, read views, and
  `UniversalReader` support so its storage can be read through delegatecall.
- **`FuseWhitelistAccessControl`** — OpenZeppelin `AccessControlUpgradeable` with one
  `bytes32` role per operation (`keccak256` of the name).
- **`FuseWhitelistLib`** — ERC-7201 namespaced storage and the list logic.

## Data model

| Concept        | Storage                                                                                            | Managed by                                        |
| -------------- | -------------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| fuse types     | `uint16 id -> string name`                                                                         | `addFuseTypes` — `FUSE_TYPE_MANAGER_ROLE`         |
| fuse states    | `uint16 id -> string name`                                                                         | `addFuseStates` — `FUSE_STATE_MANAGER_ROLE`       |
| metadata types | `uint16 id -> string name`                                                                         | `addMetadataTypes` — `FUSE_METADATA_MANAGER_ROLE` |
| fuses          | `FuseInfo {state, type, address, timestamp, metadata}` per address, lists by type and by market id | `addFuses` — `ADD_FUSE_MANAGER_ROLE`              |

`addFuses(address[] fuses, uint16[] types, uint16[] states, uint32[] deploymentTimestamps)`
rejects an address already present (`FuseWhitelistFuseAlreadyExists`), stores the info, and
calls `MARKET_ID()` on the fuse to file it under that market; a fuse without `MARKET_ID()`
(some reward fuses) is stored but not indexed by market.

Updates: `updateFuseType` (`UPDATE_FUSE_TYPE_MANAGER_ROLE`), `updateFuseState`
(`UPDATE_FUSE_STATE_MANAGER_ROLE`), `updateFuseMetadata` / `updateFusesMetadata`
(`UPDATE_FUSE_METADATA_MANAGER_ROLE`), `updateFuseDeploymentTimestamp` /
`updateFusesDeploymentTimestamps` (`UPDATE_FUSE_DEPLOYMENT_TIMESTAMP_MANAGER_ROLE`).

Views: `getFuseTypes`, `getFuseTypeDescription`, `getFuseStates`, `getFuseStateName`,
`getMetadataTypes`, `getMetadataType`, `getFusesByType`, `getFuseByAddress`,
`getFuseMetadataInfo`, `getFusesByMarketId`, `getFusesByTypeAndMarketIdAndStatus`.

## Roles

`initialize(initialAdmin)` grants `DEFAULT_ADMIN_ROLE` to the given address (meant to be a
multisig); that role authorises upgrades (`_authorizeUpgrade`) and grants the operational
roles above. These are `AccessControl` roles of the whitelist contract, unrelated to the
`Roles.sol` ids of a Plasma Vault.

## Deployed Contracts

From the IPOR ABI registry (`IPOR-Labs/ipor-abi`, `mainnet/mainnet-ethereum-fusion/addresses.json`
at commit `a0089cf`), read on Ethereum at block 25939091:

| Registry name                  | Address                                      | Observation                                                                                                    |
| ------------------------------ | -------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `IporFusionFuseWhitelistProxy` | `0xF3d8785F351251f715c142132860dF53318C2867` | 176-byte proxy runtime code; the whitelist selectors live in the implementation                                |
| `IporFusionFuseWhitelistImpl`  | `0xfB863B20E075214e8c6a41d681Eea373F317C9dD` | 20850-byte runtime code containing `addFuses(...)` `0xaee33c3b` and `getFusesByMarketId(uint256)` `0xcf3b3d68` |

The same pair is registered on every chain the registry covers (Arbitrum, Base, Ink, Unichain,
Avalanche, Botanix, Flare, HyperEVM, Katana, Monad, Plasma, Robinhood); only Ethereum was read.
Whether the proxy pointed at that implementation at the block was not checked.

## Tests

- [`test/fuses/whitelist/FuseWhitelistTest.t.sol`](../../../test/fuses/whitelist/FuseWhitelistTest.t.sol)
  — local (fresh `ERC1967Proxy` + `FuseWhitelist`), 87 tests across two suites, green on
  2026-09-09 with the default profile.

## Notes

- The `WhitelistWrappedPlasmaVaultFactory*` and `IporPlasmaVault*WhitelistUser` registry names
  are unrelated: they concern depositor whitelisting of wrapped vaults, not this fuse registry.

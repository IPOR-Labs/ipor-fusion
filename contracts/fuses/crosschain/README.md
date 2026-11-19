# Crosschain fuses

Short index of the crosschain fuse family. The detailed behaviour, deployment steps, limits and recovery runbooks live
in the transport READMEs:

- [Chainlink CCIP](../../crosschain/ccip/README.md)
- [Stargate V2 / LayerZero V2](../../crosschain/stargate/README.md)

## Market

All fuses of this family work on `IporFusionMarkets.CROSSCHAIN` (market id `54`). A PlasmaVault deploys capital into
PlasmaVaults on remote chains through a per-vault executor on the source chain and a dispatcher on the destination chain.
The executor's immutable `MANAGER()` is the PlasmaVault, so every manager-only executor operation is reachable only
through these fuses. Each fuse checks that the executor's `MANAGER()` equals the calling vault.

## Substrates

Substrates are typed `bytes32` values encoded by `lib/CrosschainSubstrateLib.sol` (type in the high bits, address in the
low 160 bits; type `0` is invalid):

| Type | Encoding | Meaning |
|---|---|---|
| `EXECUTOR` | `EXECUTOR(address)` | A Stargate or CCIP executor the vault's fuses may drive and the balance fuse values. |
| `REMOTE_VAULT` | `REMOTE_VAULT(chainId, address)` | A remote PlasmaVault bound to its destination chain; the command fuses validate command targets and dispatcher allowlists against it. |

The allowlist of remote vaults is also enforced on the destination dispatcher.

### Valuation dependency for a non-underlying executor asset (IL-9688)

When an executor's `ASSET()` is not the vault's underlying, a claim moves that token into the vault and removes its value
from the CROSSCHAIN market (54). The token is valued again only through an `ERC20_VAULT_BALANCE` (7) market refreshed in
the same batch. The FUSE_MANAGER must grant the token in market 7 (with its price feed) and add the dependency edge
`CROSSCHAIN (54) -> ERC20_VAULT_BALANCE (7)`; the fuses do not check this. Otherwise NAV is understated until market 7
is refreshed.

### Recovery marker scopes (IL-9655)

Recovery fuses (claim, supply `exit`, the recovery-marked commands) mark the `(market, executor)` scope they drive in
transient storage, and the balance fuse serves a fallback value only for a marked executor whose `getBalance()`
reverted. Several executors can be marked in one transaction: each recovery action adds its own scope (marking the
same scope again changes nothing). A scope stays marked until the transaction ends, so a scope marked in an earlier
`execute()` batch still applies to later batches of the same transaction. The marker layout changed, so the six
crosschain fuses (`CrosschainBalanceFuse`, `CrosschainClaimFuse` and the supply and command fuses of both transports)
are redeployed and re-granted together. See the transport READMEs ("Cached-NAV fallback with several executors").

## Contents

| Path | Role |
|---|---|
| `CrosschainBalanceFuse.sol` | Balance fuse. Sums `getBalance()` of every granted `EXECUTOR`, each priced in its own `ASSET()` and returned in USD WAD. `getBalance()` is fail-closed (staleness, blocked chain), so NAV updates revert while a chain is stale. In a recovery batch it falls back to the cached market value (single executor) or to the `getBalanceUnchecked()` of each marked executor (several executors, staleness reverts only; several executors can be marked in one transaction, IL-9655). |
| `CrosschainClaimFuse.sol` | Claims settled idle executor assets back to the vault (`min(amount, idle ledger)`). Requires a granted `EXECUTOR` and `MANAGER()` equal to the vault; reports the received amount to the recovery context. |
| `stargate/StargateCrosschainSupplyFuse.sol` | `enter` bridges capital to a remote dispatcher; `exit` only requests a recall (no tokens arrive in the same transaction, so it must not be in the instant-withdraw order). |
| `stargate/StargateCrosschainCommandFuse.sol` | Forwards manager operations to a Stargate executor: register chain, create dispatcher, update remote vault allowlist, send/cancel/retry commands. `enterWithSweepFloors` sends `UPDATE_PLASMA_VAULTS` with per-vault sweep floors (`minAssets` in shared decimals, IL-9629); `enter` is unchanged. |
| `ccip/CcipCrosschainSupplyFuse.sol` | Supply fuse for CCIP executors. |
| `ccip/CcipCrosschainCommandFuse.sol` | Command fuse for CCIP executors (commands, retry, cancel). `enterWithSweepFloors` sends `UPDATE_VAULTS` with per-vault sweep floors (`minAssets` in local asset decimals, IL-9629); `enter` is unchanged. |
| `lib/CrosschainSubstrateLib.sol` | Substrate encoding and the `validate*Granted` checks. |
| `lib/CrosschainRecoveryLib.sol` | Transient recovery marker (a set of `(market, executor)` scopes, IL-9655) and recovered-value accumulator shared by the recovery fuses and the balance fuse. |

The pre-hook `CrosschainNavValidationPreHook` (`contracts/handlers/pre_hooks/pre_hooks/`) gates the share-price-sensitive
vault selectors on the freshness and non-blocked state of every granted executor. Wiring and exclusions are described in
its NatSpec and in the transport READMEs.

A vault that holds shares of a CROSSCHAIN vault (an index, a pair) has no executor of its own. It registers the same hook directly
on `deposit`, `mint`, `depositWithPermit`, `withdraw`, `redeem` and `redeemFromRequest` and passes the CROSSCHAIN vaults of its
tree as the pre-hook substrates of each of those selectors (one `bytes32` per vault, the address in the low 160 bits, the same list
on all six, one `setPreHookImplementations` call); the hook then probes `isNavHealthy` of each watched vault and reverts
`CrosschainNavValidationPreHookWatchedVaultUnhealthy` when one fails. Registering the hook replaces the previous hook of the selector
(for example a rate validator with its nested hooks), so inventory the six selectors first. Procedure, the nine limits and the gas
cost: "Vaults that hold shares of a CROSSCHAIN vault" in the CCIP and Stargate READMEs.

## Grant risks (documented, not enforced by the fuses)

The fuses do not police the consequences of governance grants and revokes. Examples:

- Do not remove an `EXECUTOR` substrate while the executor still has booked value or pending records: the balance fuse
  stops valuing it. Stop new supply, complete the remote redeem, recall all tracked idle, claim to the PlasmaVault, verify
  every bucket is zero, and only then remove the executor and the fuses (see the Recovery section of the CCIP README).
- Granting an executor whose `MANAGER()` is another vault is rejected by the fuses; granting an executor of the wrong
  transport is rejected by the supply and command fuses.
- Granting a `REMOTE_VAULT` lets the command fuses target that remote vault; review each grant.
- Grant each executor once, encoded with `CrosschainSubstrateLib.executorSubstrate()` (chainId field zero). `balanceOf`
  counts every `EXECUTOR` entry separately. Several entries that decode to the same address (an exact repeat, or a
  canonical entry plus a non-canonical alias with a non-zero chainId field) make that executor's NAV count twice or
  more. A single non-canonical entry does not cause double counting. Such entries also inflate the executor count that
  selects the recovery path (`getBalanceUnchecked()` instead of the cache). Only FUSE_MANAGER (`grantMarketSubstrates`)
  can do this, and nothing checks it on-chain (IL-8290, IL-9193).

See the transport READMEs for the full list of limitations and runbooks.

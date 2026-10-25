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

## Contents

| Path | Role |
|---|---|
| `CrosschainBalanceFuse.sol` | Balance fuse. Sums `getBalance()` of every granted `EXECUTOR`, each priced in its own `ASSET()` and returned in USD WAD. `getBalance()` is fail-closed (staleness, blocked chain), so NAV updates revert while a chain is stale. In a recovery batch it falls back to the cached market value (single executor) or to the marked executor's `getBalanceUnchecked()` (several executors, staleness reverts only). |
| `CrosschainClaimFuse.sol` | Claims settled idle executor assets back to the vault (`min(amount, idle ledger)`). Requires a granted `EXECUTOR` and `MANAGER()` equal to the vault; reports the received amount to the recovery context. |
| `stargate/StargateCrosschainSupplyFuse.sol` | `enter` bridges capital to a remote dispatcher; `exit` only requests a recall (no tokens arrive in the same transaction, so it must not be in the instant-withdraw order). |
| `stargate/StargateCrosschainCommandFuse.sol` | Forwards manager operations to a Stargate executor: register chain, create dispatcher, update remote vault allowlist, send/cancel/retry commands. |
| `ccip/CcipCrosschainSupplyFuse.sol` | Supply fuse for CCIP executors. |
| `ccip/CcipCrosschainCommandFuse.sol` | Command fuse for CCIP executors (commands, retry, cancel). |
| `lib/CrosschainSubstrateLib.sol` | Substrate encoding and the `validate*Granted` checks. |
| `lib/CrosschainRecoveryLib.sol` | Transient recovery marker and recovered-value accumulator shared by the recovery fuses and the balance fuse. |

The pre-hook `CrosschainNavValidationPreHook` (`contracts/handlers/pre_hooks/pre_hooks/`) gates the share-price-sensitive
vault selectors on the freshness and non-blocked state of every granted executor. Wiring and exclusions are described in
its NatSpec and in the transport READMEs.

## Grant risks (documented, not enforced by the fuses)

The fuses do not police the consequences of governance grants and revokes. Examples:

- Do not remove an `EXECUTOR` substrate while the executor still has booked value or pending records: the balance fuse
  stops valuing it. Stop new supply, complete the remote redeem, recall all tracked idle, claim to the PlasmaVault, verify
  every bucket is zero, and only then remove the executor and the fuses (see the Recovery section of the CCIP README).
- Granting an executor whose `MANAGER()` is another vault is rejected by the fuses; granting an executor of the wrong
  transport is rejected by the supply and command fuses.
- Granting a `REMOTE_VAULT` lets the command fuses target that remote vault; review each grant.

See the transport READMEs for the full list of limitations and runbooks.

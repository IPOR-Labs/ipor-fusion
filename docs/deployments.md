# Deployment sources and factory pilot

This document records where deployment identities come from and selects the
first network–factory pair for the agent-readiness pilot. It is discovery
evidence, not a deployment manifest and not permission to transact.

## Selected pilot

| Field                   | Value                                              |
| ----------------------- | -------------------------------------------------- |
| Network                 | Ethereum mainnet                                   |
| Chain ID                | `1`                                                |
| Registry name           | `IporFusionFactoryProxy`                           |
| Proxy address           | `0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852`       |
| Companion registry name | `IporFusionFactoryImpl`                            |
| Implementation address  | `0xf19C1E9f6616F6056AF1e322A86fDaAaAf0263f5`       |
| Status                  | **candidate — identity not yet verified on-chain** |

The source is the `fusion_address_lookup` deployment lookup exposed by
`ipor-fusion-dev`, running IPOR Fusion SDK `3.6.7`. On 2026-09-09
(Europe/Warsaw), a case-insensitive `FusionFactory` name query restricted to
chain 1 returned exactly the proxy and implementation rows above. A separate
exact-address query returned one match for the proxy. The captured, non-secret
responses are in
[`../agent-readiness/tasks/T20/address-lookup.json`](../agent-readiness/tasks/T20/address-lookup.json).

The proxy address independently appears as a configuration source in both
classified factory fork fixtures:

- [`FusionFactoryDaoFeePackagesForkTest.t.sol`](../test/factory/FusionFactoryDaoFeePackagesForkTest.t.sol)
- [`FusionFactoryBusinessClientFeePackagesForkTest.t.sol`](../test/factory/FusionFactoryBusinessClientFeePackagesForkTest.t.sol)

Those fixtures deploy a fresh factory and therefore do **not** prove that this
deployment can create a vault. The RPC doctor also proved only that non-empty
code was readable at this address on block `23831825`.

Ethereum is selected because the repository already has a pinned archive-state
fixture at block `23831825`, the configured provider served that state during
T18, and the deployment lookup names both a proxy and an implementation. This
does not assume that the deployed interface matches the current checkout.

## Source responsibilities

Keep the layers separate:

| Source                                                              | Data accepted from it                                                                       | Data not inferred from it                                                                       |
| ------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `fusion_address_lookup` / its deployment dataset                    | Network, registry name and address used to discover a candidate.                            | Current proxy slot, runtime bytecode, deployment transaction, roles, fees or ABI compatibility. |
| Verified explorer source through `contract_source` / `contract_abi` | Compiler metadata, verified source and ABI for the addressed deployed version.              | Current mutable configuration or authorization.                                                 |
| Local `deployments/<chain-id>/factories.json` (from T23 onward)     | Reviewed identity, provenance, ABI reference, hashes, dependencies and evidence references. | Live state beyond the manifest's recorded block.                                                |
| Direct RPC reads (`factory:inspect` from T24 onward)                | Code, implementation, components, caller-specific fees and roles at a named block.          | Permanent truth after that block.                                                               |

The local repository will maintain the versioned ABI, manifest, hashes and
reproducible verification report. It will not copy the whole upstream address
database. The upstream lookup remains the discovery source and should be
queried again when adding a network or deployment.

## Known gaps before registration

The address lookup response did not include a deployment transaction, deployment
block, proxy type, runtime hashes, ABI provenance or a verification block hash.
Do not invent those values. T21 defines their schema, T22 binds an ABI to the
deployed code, T23 creates a `candidate` manifest, and T24 performs the direct
on-chain identity/configuration read. Promotion to `verified` waits for T25 and
T26.

# Deployment sources and factory pilot

This document records where deployment identities come from and selects the
first network–factory pair for the factory pilot. It is discovery
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
| Status                  | **verified at Ethereum block `25937526`**          |

The source is the `fusion_address_lookup` deployment lookup exposed by
`ipor-fusion-dev`, running IPOR Fusion SDK `3.6.7`. On 2026-09-09
(Europe/Warsaw), a case-insensitive `FusionFactory` name query restricted to
chain 1 returned exactly the proxy and implementation rows above. A separate
exact-address query returned one match for the proxy. The captured, non-secret
responses are in
[`../deployments/evidence/ethereum-fusion-factory-address-lookup-2026-09-09.json`](../deployments/evidence/ethereum-fusion-factory-address-lookup-2026-09-09.json).

The proxy address independently appears as a configuration source in both
classified factory fork fixtures:

- [`FusionFactoryDaoFeePackagesForkTest.t.sol`](../test/factory/FusionFactoryDaoFeePackagesForkTest.t.sol)
- [`FusionFactoryBusinessClientFeePackagesForkTest.t.sol`](../test/factory/FusionFactoryBusinessClientFeePackagesForkTest.t.sol)

Those fixtures deploy a fresh factory and therefore do **not** prove that this
deployment can create a vault. The RPC doctor also proved only that non-empty
code was readable at this address on block `23831825`.

Ethereum is selected because the repository already has a pinned archive-state
fixture at block `23831825`, the configured provider served that state in the
fork suite, and the deployment lookup names both a proxy and an implementation. This
does not assume that the deployed interface matches the current checkout.

## Source responsibilities

Keep the layers separate:

| Source                                                              | Data accepted from it                                                                       | Data not inferred from it                                                                       |
| ------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `fusion_address_lookup` / its deployment dataset                    | Network, registry name and address used to discover a candidate.                            | Current proxy slot, runtime bytecode, deployment transaction, roles, fees or ABI compatibility. |
| Verified explorer source through `contract_source` / `contract_abi` | Compiler metadata, verified source and ABI for the addressed deployed version.              | Current mutable configuration or authorization.                                                 |
| Local `deployments/<chain-id>/factories.json`                       | Reviewed identity, provenance, ABI reference, hashes, dependencies and evidence references. | Live state beyond the manifest's recorded block.                                                |
| Direct RPC reads (`factory:inspect`)                                | Code, implementation, components, caller-specific fees and roles at a named block.          | Permanent truth after that block.                                                               |

The local repository will maintain the versioned ABI, manifest, hashes and
reproducible verification report. It will not copy the whole upstream address
database. The upstream lookup remains the discovery source and should be
queried again when adding a network or deployment.

## Pilot ABI

The verified explorer source links the selected proxy to implementation
`0xf19c1e9f6616f6056af1e322a86fdaaaaf0263f5`. The implementation is named
`FusionFactory` and was compiled with Solidity `0.8.30`, optimizer enabled at
`200` runs and Cancun EVM. These are deployment facts; they deliberately differ
from the current repository's optimizer settings.

Its 78-entry ABI and provenance are versioned by implementation identity:

- [`FusionFactory.abi.json`](../abi/fusion-factory-ethereum-0xf19c1e9f6616f6056af1e322a86fdaaaaf0263f5/FusionFactory.abi.json)
- [`provenance.json`](../abi/fusion-factory-ethereum-0xf19c1e9f6616f6056af1e322a86fdaaaaf0263f5/provenance.json)

Validate the recorded SHA-256 and the required creation operation:

```bash
npm run validate:pilot-abi
```

The check finds exactly one
`clone(string,string,address,uint256,address,uint256)` entry, verifies selector
`0x8697b10a`, encodes representative calldata with Foundry `cast`, and decodes
it back to all six inputs. No adapter is needed for this operation because the
deployed ABI and current source expose the same signature. That statement is
limited to the signature; it does not claim behavioral compatibility.

## Manifest contract

The machine-readable schema is
[`../deployments/schema/factories.schema.json`](../deployments/schema/factories.schema.json).
Production manifests use `deployments/<chain-id>/factories.json` and contain:

- stable identity, chain, kind, status and callable address;
- proxy type, implementation and implementation slot;
- address provenance plus deployment transaction/block when known;
- runtime hashes, source commit and compiler/linker settings;
- a repository-relative ABI path with its SHA-256;
- component dependencies; and
- a block-specific verification record with inspect report and compatibility
  test references.

Validate the schema, references and cross-field rules with:

```bash
npm run validate:deployments
```

The first production manifest is
[`../deployments/1/factories.json`](../deployments/1/factories.json). The
validator also retains the synthetic candidate under
`test/fixtures/deployments/`. Fixtures may reference fixture ABIs; production
manifests must reference `abi/`.

Schema validity is necessary but not sufficient. The validator checks file
existence and ABI hashes, rejects chain/directory disagreement and refuses
`verified` unless every proof field is populated. It cannot establish that
those populated values are truthful; the referenced inspection and test are
the reviewable evidence.

## Inspecting the pilot

Run the read-only inspector with an explicit chain, deployment ID, historical
block and caller:

```bash
npm run factory:inspect -- \
  --chain 1 \
  --deployment ethereum-fusion-factory-cd05909c \
  --block 25937526 \
  --caller 0x1111111111111111111111111111111111111111
```

The command reads the provider name from the test catalog, resolves its value
from the environment or ignored `.env`, and never prints that value. It checks
the provider chain, block hash, proxy and implementation bytecode, ERC-1967
implementation slot and ABI hash before decoding factory version, components,
timing and both global and caller-effective fee packages. Failures distinguish
at least `CHAIN_MISMATCH`, `NO_CODE`, `IMPLEMENTATION_MISMATCH` and
`UNSUPPORTED_FACTORY_VERSION`.

The captured factory inspection is
[`../deployments/evidence/ethereum-fusion-factory-inspection-25937526.json`](../deployments/evidence/ethereum-fusion-factory-inspection-25937526.json).
It is pinned to Ethereum block `25937526` and caller `0x1111…1111`. The report
shows factory version 8 and the expected implementation, but the inspector
itself never mutates or promotes a manifest entry; promotion is the separate,
reviewed step recorded below. An inspection at block `23831825` instead reports an implementation
mismatch because the proxy still pointed to an older implementation there.

The deployed-usage test exercises the same identity without replacing or
upgrading it:

```bash
npm run test:fork -- --chain 1 --suite deployed-factory --block 25937526
```

The test's creation exists only in ephemeral fork state. A pass is evidence for
the permissionless clone path and its resulting owner/component/fee state at
that block; it is not a transaction receipt and does not promote the manifest
on its own.

## Verification record

The pilot entry is `verified`. The evidence is a secret-free report, not a
sentence in this document:

- [`../deployments/reports/ethereum-fusion-factory-cd05909c-25937526.json`](../deployments/reports/ethereum-fusion-factory-cd05909c-25937526.json)

It pins block `25937526` and its hash, names the toolchain that produced it
(Foundry `1.7.1`, Node `v24.16.0`, the inspector script with its SHA-256), and
records four things that were actually observed at that block:

1. proxy and implementation runtime code hashes, the ERC-1967 slot value and the
   ABI hash bound to that implementation;
2. reported factory version `8`, component addresses, timing and both fee
   package sets, reproduced identically to the captured inspection;
3. non-empty runtime code with its hash at all sixteen component addresses; and
4. the deployed-usage compatibility test, its file hash and its passing result
   without any upgrade, code replacement, role grant or broadcast.

Every step is listed with its command under `reproduce` in the report. The
provider is referenced by variable name only; no URL or key is stored.

Re-verification is required, and the entry drops back to `candidate`, whenever
the implementation slot, a component address or the ABI changes. The recorded
values are observations at one block, not permanent constants: read them again
before preparing any operation.

## Second verified entry: the ERC4626 price feed factory

`ethereum-erc4626-price-feed-factory-f58fcce9` follows the same rules as the
FusionFactory entry and is `verified` at the same block:

| Field                  | Value                                        |
| ---------------------- | -------------------------------------------- |
| Proxy                  | `0xf58Fcce9370aBa552032d3EA47baA486F70c0FdC` |
| Implementation         | `0xe08AfF4910Fb61AcC2EacB03b0a6132B01D1aa61` |
| Operation              | `create(address,address)` — `0x3e68680a`     |
| Required dependency    | the price oracle middleware `0xC9F32d65…64c6` |
| Evidence               | [`…-f58fcce9-25937526.json`](../deployments/reports/ethereum-erc4626-price-feed-factory-f58fcce9-25937526.json) |

Two things about this factory are worth knowing before using it:

- It has **no version getter**. Its identity is the implementation address, the
  runtime code hash and the verified ABI — the manifest's `reportedVersion` is
  `null` on purpose, and the drift job compares code rather than a version number.
- The feed it creates asks **`msg.sender`** for the underlying asset's price
  ([`ERC4626PriceFeed.sol`](../contracts/price_oracle/price_feed/ERC4626PriceFeed.sol)),
  so `latestRoundData()` only answers meaningfully when the caller is a price
  oracle middleware or its manager. Reading it from anywhere else is not a
  smaller answer, it is a different question.

The compatibility test creates a feed for Steakhouse USDC through the unchanged
factory and checks the reading against a value recomputed from the same sources:

```bash
npm run test:fork -- --chain 1 --suite deployed-price-feed-factory --block 25937526
```

The implementation's own verified compiler metadata was not captured, so
`code.compiler` is `null` here while the ABI is verified — an honest `null`
rather than the proxy's settings borrowed for the implementation.

## A second network: Base

`deployments/8453/factories.json` registers the Base FusionFactory, verified at
Base block `51000000`:

| Field           | Value                                        |
| --------------- | -------------------------------------------- |
| Proxy           | `0x1455717668fA96534f675856347A973fA907e922` |
| Implementation  | `0x610152A79BE7F2Aa3aA70520c9331c18fe8D33b7` |
| Reported version| `8` — the same family as the Ethereum entry  |
| Underlying used | Base USDC `0x833589fC…2913`                  |
| Evidence        | [`base-fusion-factory-14557176-51000000.json`](../deployments/reports/base-fusion-factory-14557176-51000000.json) |

Nothing is shared between the two networks except the ABI file and the reported
version. Addresses, tokens, blocks, profiles and tests are separate, and the test
asserts that the two factory addresses differ so that a copy-paste mistake fails
rather than passes.

```bash
npm run test:fork -- --chain 8453 --suite deployed-factory --block 51000000
npm run agent:doctor -- --rpc --chain 8453 --block 51000000
```

Two honest limits on this entry:

- The Base implementation's **bytecode differs** from the Ethereum one (15 KB
  against 22 KB) even though both report version 8. The ABI is reused on the
  strength of the reported version and of reads that answered, not on a bytecode
  match — `provenance.json` says exactly that.
- A byte search for the ABI's function selectors found 42 of 43 in the Base
  implementation. The missing one, `getVestingPeriodInSeconds()`, **answers when
  called** (`604800`): a selector probe can miss a dispatch pattern, so its
  absence from a search is not absence from the contract. The report records the
  probe and its resolution rather than the probe alone.

`factory:inspect` is not wired to this entry; it reads the Ethereum pilot's
component set. Extending it to another network is a separate change, exactly as
adding a network with a different ABI family would need its own adapter task.

## Known gaps after verification

The address lookup response did not include a deployment transaction, deployment
block or source commit, and verification did not establish them. Do not invent
those values — they stay explicitly `null` in the manifest. `verified` here means
that the identity, ABI, components and one real creation path were checked at a
named block; it does not mean the entry's full history is known.

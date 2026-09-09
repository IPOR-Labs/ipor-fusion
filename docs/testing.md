# Testing

How to choose a test suite, run it, and read its result correctly.

This document starts from the factory pilot, which is the only area classified so
far. It grows one area at a time, together with
[`../config/test-suites.json`](../config/test-suites.json).

## The catalog

[`../config/test-suites.json`](../config/test-suites.json) classifies test
suites. Each entry records what the suite needs in order to run and what its
fixture actually proves:

| Field                   | Meaning                                                                     |
| ----------------------- | --------------------------------------------------------------------------- |
| `group`, `path`         | The CLI suite group and the test file it selects.                           |
| `contracts`, `chainId`  | Test contracts and their fork network (`null` for local).                   |
| `stateProbe`            | Code-bearing address used only to test historical state availability.       |
| `fixture`               | What the fixture builds — see the four types below.                         |
| `profile`               | The Foundry profile the suite runs under.                                   |
| `rpc`                   | The provider environment **variable name**, or `null` when none is needed.  |
| `block`                 | The pinned fork block, or `null`.                                           |
| `ffi`                   | Whether the suite actually calls `vm.ffi`.                                  |
| `tests`                 | The number of test functions at the last classification run.                |
| `setUp`                 | What the fixture deploys, mutates, and which on-chain addresses it touches. |
| `proves`/`doesNotProve` | The claim the suite supports, and the claim it does not.                    |

The schema is [`../config/test-suites.schema.json`](../config/test-suites.schema.json).
Validate the catalog after any change:

```bash
npm run validate:test-suites
```

The validator checks the schema, that every `path` exists in the checkout, that
ids are unique, that a forking fixture declares a chain ID, provider variable
and pinned block, and that a local fixture declares none of those. It exits
non-zero and names the offending entry when a rule is broken.

### What is not classified

Only `test/factory/*.t.sol` at the top level of that directory is classified.
Everything else under `test/` — including `test/factory/price_feed/` — is
deliberately unclassified. **An unlisted suite carries no claim in either
direction.** Its absence is not evidence that it is local, that it forks, or
that it is unnecessary. Read its `setUp()` before quoting its result.

## The four fixture types

| Fixture                 | What may differ from the live chain                                                  | What a pass proves                               |
| ----------------------- | ------------------------------------------------------------------------------------ | ------------------------------------------------ |
| `local-deployment`      | Everything; there is no chain state.                                                 | The checked-out code behaves as written.         |
| `fork-fresh-deployment` | The contract under test is deployed by the fixture; surrounding protocols are real.  | The checked-out code works among real protocols. |
| `fork-upgrade`          | An existing proxy is deliberately upgraded or reconfigured.                          | The new version would work if it were deployed.  |
| `deployed-usage`        | Only the state the tested operation creates, plus explicit funding of test accounts. | The live deployment is usable as it stands.      |

Only the last type supports a statement about a deployment. **No suite in this
repository currently has that type**, so nothing here yet proves that a deployed
factory can create a vault. Producing that evidence is separate planned work; see
[`../agent-readiness/PLAN.md`](../agent-readiness/PLAN.md).

The trap is specific and worth stating plainly: both fork suites under
`test/factory/` read the mainnet `FusionFactory` proxy, but only to copy its
configuration. They then deploy their own factory implementation, their own
proxy, their own `PlasmaVaultFactory`, `FeeManagerFactory` and core base —
because the deployed components do not accept the current `PlasmaVaultInitData`
shape. They are `fork-fresh-deployment`. Reporting one of them as proof that the
deployed factory works is wrong.

## Running the factory pilot suites

Local, no credentials required — 129 tests across five suites:

```bash
npm run test:unit
```

This command validates the catalog, selects every `local-deployment` entry and
runs entries grouped by the profile recorded in each one. It overrides the
catalogued provider variables with an unreachable loopback endpoint in the
Forge child process, so an accidental RPC dependency fails instead of using
credentials from the caller's environment or `.env`. An empty selection,
invalid catalog or Forge failure returns a non-zero exit code.

The current scope is intentionally narrow: the five top-level factory suites
below, covering local FusionFactory composition and access control, DAO and
business-client fee-package logic, fuse-manager timelock cancellation, and the
plain and whitelist wrapper factories. It does not cover any unclassified test,
fork behavior, real deployment, price-feed factory or protocol integration.

Equivalent individual Forge commands for diagnosis are:

```bash
FOUNDRY_PROFILE=factory_local forge test --match-path 'test/factory/FusionFactory.t.sol'
FOUNDRY_PROFILE=factory_local forge test --match-path 'test/factory/FusionFactoryBusinessClientFeePackagesTest.t.sol'
FOUNDRY_PROFILE=factory_local forge test --match-path 'test/factory/FuseManagerTimelockCancelTest.t.sol'
FOUNDRY_PROFILE=factory_local forge test --match-path 'test/factory/WrappedPlasmaVaultFactory.t.sol'
FOUNDRY_PROFILE=factory_local forge test --match-path 'test/factory/WhitelistWrappedPlasmaVaultFactory.t.sol'
```

Fork, requires an archive-capable Ethereum endpoint — 12 tests across two
suites. Always provide the intended block explicitly:

```bash
npm run test:fork -- --chain 1 --suite factory --block 23831825
```

The runner validates the catalog, rejects an unsupported chain or suite, checks
that exactly one provider and profile apply, and fails before Forge when the
provider variable is absent. It exports `FUSION_FORK_BLOCK`; both fixtures read
that value when creating the fork and contain a test asserting the selected
`block.number`. This handshake makes a supplied-but-ignored block a test
failure. The catalog value remains the reviewed reference block, while the CLI
argument is the block actually exercised by this invocation.

For diagnosis, the equivalent individual commands are:

```bash
FUSION_FORK_BLOCK=23831825 FOUNDRY_PROFILE=factory_ethereum forge test --match-path 'test/factory/FusionFactoryDaoFeePackagesForkTest.t.sol'
FUSION_FORK_BLOCK=23831825 FOUNDRY_PROFILE=factory_ethereum forge test --match-path 'test/factory/FusionFactoryBusinessClientFeePackagesForkTest.t.sol'
```

## Providers, profiles and FFI

Fork suites read a provider through `vm.envString`. Copy
[`../.env.example`](../.env.example), fill in your own URLs, and keep them there:
the file is ignored by Git. Foundry reads `.env` from the repository root by
itself, so no shell sourcing is needed; a variable already exported into the
environment takes precedence over the file. Only variable **names** belong in
documents, catalogs, logs and reports — never a URL, since provider URLs usually
embed a key.

Pinned blocks need archive state. An endpoint that serves only recent state will
fail on a historical block; that is an infrastructure result, not a protocol one.

Check one provider before starting a fork suite:

```bash
npm run agent:doctor -- --rpc --chain 1 --block 23831825
```

This opt-in mode first calls `eth_chainId` and then `eth_getCode` for the
catalogued `stateProbe` at the requested block. It reports `RPC_UNAVAILABLE`,
`CHAIN_MISMATCH` and `HISTORICAL_STATE_UNAVAILABLE` separately and never prints
the URL or the provider's error body. A successful probe proves only that the
endpoint serves code at that chain and block. It does not verify the identity or
configuration of the probed deployment.

The catalog selects a profile per suite. Pass it explicitly when invoking Forge:

```bash
FOUNDRY_PROFILE=factory_local forge test --match-path 'test/factory/FusionFactory.t.sol'
FOUNDRY_PROFILE=factory_ethereum forge test --match-path 'test/factory/FusionFactoryDaoFeePackagesForkTest.t.sol'
```

The effective profile matrix is:

| Profile            | Purpose                                     | EVM       | FFI     | Filesystem access     |
| ------------------ | ------------------------------------------- | --------- | ------- | --------------------- |
| `default`          | Backwards-compatible, unclassified test use | Cancun    | enabled | read-write repository |
| `ci`               | Existing full reusable CI workflow          | Cancun    | enabled | read-write repository |
| `factory_local`    | Classified RPC-free factory pilot           | Cancun    | denied  | none                  |
| `factory_ethereum` | Classified Ethereum factory pilot           | Cancun    | denied  | none                  |
| `arbitrum`         | Existing Arbitrum suites                    | **Paris** | enabled | read-write repository |

Every named profile inherits `solc = "0.8.30"`, `optimizer_runs = 10000000`,
`isolate = false`, remappings and all other settings from `default`. The `ci`
table is now explicit but deliberately preserves the previous effective
configuration because that workflow still runs unclassified suites. Likewise,
`arbitrum` keeps its sole historical override, `evm_version = "paris"`.

Only the two factory-pilot profiles narrow capabilities: both deny FFI and have
an empty `fs_permissions` list. No classified suite calls `vm.ffi` or a
filesystem cheatcode. The catalog's `ffi` field records actual use and the
profile now enforces it. `isolate = false` remains unchanged because other test
suites write transient storage in one call and read it in another.

## Choosing what to run for a change

Use the conservative catalog-driven selector for a branch or working tree:

```bash
npm run test:affected -- --base origin/main
npm run test:affected -- --base origin/main --json
```

It combines committed, staged, unstaged and untracked paths. JSON mode prints a
plan without executing tests. Default mode executes the selected scope through
`test:unit` and `test:fork`, so a required but missing RPC is a failure rather
than a skipped success.

The pilot rules intentionally prefer a safe superset:

- a factory change selects every classified factory suite;
- storage, vault, access or oracle changes select the entire classified catalog;
- a relative Solidity import selects its importing suite transitively;
- an unknown helper, unclassified test or unrecognized path selects the entire
  catalog and reports that it widened conservatively;
- documentation and readiness metadata alone select validation only.

| Changed area                              | Start with                                                                                                                               |
| ----------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| A factory                                 | `test/factory/`, then the fee-package suites if fees are involved.                                                                       |
| A fuse                                    | `test/fuses/<integration>/` or `test/unitTest/fuses/<integration>/`; see [`../contracts/fuses/AGENTS.md`](../contracts/fuses/AGENTS.md). |
| Vault storage, accounting, access, oracle | The direct suite, plus the callers the change can reach.                                                                                 |
| A shared library                          | Its own suite, then every area that depends on it.                                                                                       |
| Documentation only                        | Link, command, formatting and diff checks. Contract suites are not automatically necessary.                                              |

Widen from the smallest relevant suite according to the trust boundary the change
crosses, not by running everything.

## Reading a failure

Separate these before reporting anything:

- **Infrastructure** — provider unset, endpoint unreachable, missing archive
  state, rate limiting. Not a protocol result in either direction.
- **Fixture** — the setup no longer builds: a changed initializer shape, a
  removed role, a stale copied configuration. The test never reached the
  behavior under test.
- **Regression** — the behavior under test changed. This is the only category
  that says something about the code.
- **Inherited** — the failure already exists on the base commit. Verify before
  attributing it to your change, and report it separately.

A regression test must reach the defective path and fail for the intended reason
when the fix is reverted; a test that passes without exercising the fix is not
evidence.

## Related documents

- [`../test/AGENTS.md`](../test/AGENTS.md) — scoped instructions for working in `test/`.
- [`../contracts/factory/AGENTS.md`](../contracts/factory/AGENTS.md) — factory test modes.
- [`../contracts/fuses/AGENTS.md`](../contracts/fuses/AGENTS.md) — fuse test selection.
- [`roles-and-permissions.md`](roles-and-permissions.md) — callers, owners and delays a test must not collapse.

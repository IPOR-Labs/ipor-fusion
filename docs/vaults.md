# Creating a vault through a deployed factory

This document covers the **input** to one vault creation: what the caller has to
state, what the repository checks before anything touches a network, and which
questions deliberately stay unanswered until the operation is planned against
chain state.

It describes the pilot only: the `verified` Ethereum FusionFactory registered in
[`../deployments/1/factories.json`](../deployments/1/factories.json). See
[deployments.md](deployments.md) for how that entry was verified.

## The input file

The schema is
[`../config/vaults/vault-creation.schema.json`](../config/vaults/vault-creation.schema.json)
and the worked example is
[`../config/vaults/example.json`](../config/vaults/example.json):

```bash
npm run validate:vault-config                       # checks the shipped example
npm run validate:vault-config -- path/to/input.json # checks your own input
npm run validate:vault-config -- path/to/input.json --json
```

Exit codes: `0` valid, `1` invalid, `2` an input file could not be read.

| Field                            | Meaning                                                                             |
| -------------------------------- | ----------------------------------------------------------------------------------- |
| `chainId`, `deploymentId`        | Which registered deployment this input is for. Both must resolve to one manifest entry. |
| `variant`                        | Which creation entry point is meant. See the table below.                           |
| `caller`                         | The address that will send the transaction to the factory.                          |
| `vault.owner`                    | The address that receives `OWNER_ROLE` on the new vault.                            |
| `vault.underlying`               | Address, symbol and `decimals` of the underlying token, stated, not inferred.       |
| `vault.redemptionDelaySeconds`   | Redemption delay in whole seconds.                                                  |
| `fees.packageIndex`              | Index passed to the factory.                                                        |
| `fees.packageSource`             | Which list that index is read from for this caller.                                 |
| `fees.expected`                  | What the caller expects the selected package to contain, recipient included.        |

## Units are part of the field name

`*Seconds` is whole seconds, `*Bps` is basis points of `10000`, and `decimals`
is the token's own decimals. Token amounts, once later steps need them, are
decimal strings in the smallest unit. The validator rejects a value whose type
disagrees with its name — `"1 hour"`, `0.5` seconds or a management fee written
as `0.05` are all errors, not rounded guesses.

## Caller, owner and signer are three different roles

The factory picks the fee package list by `msg.sender`
([`FusionFactoryLogicLib`](../contracts/factory/lib/FusionFactoryLogicLib.sol)),
not by the requested owner. A Safe, an EOA and a helper contract calling the
same factory with the same arguments can therefore get different fees. The input
names the `caller` separately from `vault.owner` for that reason; the signer
behind a Safe is a third thing again and does not appear here at all.

`fees.packageSource` records which list the caller believes applies:

- `dao-global` — the global DAO packages, used when the caller has no
  business-client packages configured;
- `business-client` — the caller's own list, which shadows the global one and is
  indexed independently.

The validator does not decide which one is true — that is chain state at
execution time, read by the planning step.

## Supported variants

| Variant                 | Factory function                                            | Pilot support                                                  |
| ----------------------- | ------------------------------------------------------------ | -------------------------------------------------------------- |
| `permissionless-clone`  | `clone(string,string,address,uint256,address,uint256)`      | Supported. Any caller may use it.                              |
| `supervised-clone`      | `cloneSupervised(...)`                                       | Rejected: it requires `MAINTENANCE_MANAGER_ROLE` and the manifest does not list it as a supported operation. |

A variant is accepted only when the named deployment lists its operation in
`interface.supportedOperations`. Adding a variant therefore means proving the
deployment supports it, not editing this table.

## No hidden defaults

Nothing in this input is filled in for the user:

- the fee recipient must be stated explicitly, and the zero address is refused;
- the owner is required, and never falls back to the caller;
- the underlying token's `decimals` is stated, not read from an assumption;
- an unknown property is an error rather than a silently ignored override.

An input naming a `candidate` or missing deployment is rejected with
`UNVERIFIED_DEPLOYMENT` / `UNKNOWN_DEPLOYMENT`. Validation reads no RPC: it
proves the input is well formed and internally consistent with the registry, not
that the operation will succeed.

## Planning one creation

`vault:plan` turns a validated input plus one historical block into a plan
artifact. It signs nothing and sends nothing:

```bash
npm run vault:plan -- --config config/vaults/example.json --block 25937526
npm run vault:plan -- --config config/vaults/example.json --block 25937526 --out plan.json
```

Exit codes: `0` planned, `1` refused, `2` bad arguments or an unreadable file.

The artifact carries what a reviewer needs to check the operation before anybody
signs it:

- `transaction`: `to`, `from`, `value` (`"0"`), the calldata and the decoded
  arguments beside it;
- `expected`: the implementation behind the proxy, the reported factory version
  and the fee package the factory resolves **for this caller**;
- `readBlock`: the block number and hash every read was answered at;
- `input`: the config path and the SHA-256 of its exact bytes.

Check the calldata independently — it decodes back to the input:

```bash
cast decode-calldata "clone(string,string,address,uint256,address,uint256)" <data>
```

Planning stops, with no artifact written, when the operation would not be the
one described:

| Error                          | Cause                                                                     |
| ------------------------------ | ------------------------------------------------------------------------- |
| `INVALID_CONFIG`               | The input fails the schema or the registry checks above.                  |
| `UNVERIFIED_DEPLOYMENT`        | The manifest entry is not `verified`.                                     |
| `UNKNOWN_DEPLOYMENT`           | No such deployment for that chain.                                        |
| `IMPLEMENTATION_MISMATCH`      | The proxy points at an implementation the manifest does not name.         |
| `UNSUPPORTED_FACTORY_VERSION`  | The factory reports a version other than the recorded one.                |
| `FEE_PACKAGE_MISMATCH`         | The resolved list, the index or the package's values/recipient differ from `fees.expected`. |
| `CHAIN_MISMATCH`               | The provider serves a different chain than the input names.               |
| `HISTORICAL_STATE_UNAVAILABLE` | The provider cannot serve that block.                                     |
| `RPC_UNAVAILABLE`              | The provider variable is unset or unanswering.                            |

A plan is valid only for the identity and fees it recorded. If the factory is
upgraded, or the caller's fee packages change, the plan must be rebuilt — the
tooling will not silently accept the new state. The provider is named by
variable only; no URL reaches the artifact or the error messages.

## Simulating the plan

`vault:simulate` runs exactly the plan's calldata on an ephemeral local fork, as
the caller the plan names:

```bash
npm run vault:plan -- --config config/vaults/example.json --block 25937526 --out plan.json
npm run vault:simulate -- --plan plan.json
npm run vault:simulate -- --plan plan.json --block 25937526 --out simulation.json
```

Exit codes: `0` the simulation ran — read `status` in the report for `success`
or `reverted` — `1` refused, `2` bad arguments or an unreadable file.

The fork is an `anvil` process started for this one command against the pinned
block and killed afterwards. Nothing is broadcast, and `fork.broadcast` in the
report says so explicitly.

The report states the outcome (`success`/`reverted`), the gas used, the fork
block and its hash, the SHA-256 of the plan file it ran and of the input that
plan was built from, plus, on success, the created component addresses.

Those addresses are read twice and must agree: once from the return value of the
call at the pre-transaction state, and once from the `FusionInstanceCreated`
event the factory emitted. The deployed ABI does not contain that event — it is
emitted from a library — so its signature comes from the repository source and is
accepted only because the observed topic equals the hash of that signature. A
disagreement between the two readings is `SIMULATION_INCONSISTENT`, not a
silently preferred value.

What the simulation deliberately does not do:

- it does not upgrade the factory, replace code or grant anybody a role to make
  the run succeed — a caller that cannot do the operation is reported, not fixed;
- it does not support a caller with code (a Safe or a helper contract), which is
  refused with `UNSUPPORTED_EXECUTION_PATH` instead of being approximated by an
  EOA;
- it refuses to run a plan whose implementation is not the one behind the proxy
  on the fork (`IMPLEMENTATION_MISMATCH`).

The only state the command creates is local: the caller is impersonated and
funded on the fork so that it can pay simulated gas. The created addresses exist
only in that fork; a real transaction produces different ones.

## Verifying the created vault

Addresses coming back from a creation prove nothing on their own, so every
successful simulation is verified before it is reported as a success. The rules
live in [`../tools/lib/vault-state.mjs`](../tools/lib/vault-state.mjs) and are
shared by the simulation and by any later check of a real creation.

Reading and checking are deliberately separate: one function reads the chain,
another decides. That keeps the rules testable without a network, against the
readings captured from a real creation in
[`../test/fixtures/vault-state/created-vault.json`](../test/fixtures/vault-state/created-vault.json).

```bash
npm run vault:state:test      # the rules, offline
npm run vault:simulate:test   # the rules against a real fork run
```

The 29 checks cover four groups:

1. **Existence** — each of the seven created components is a non-zero address
   with runtime code. This is the weakest evidence, and it is never the only one.
2. **Identity** — the vault's asset, name, symbol, decimals and the underlying
   token's decimals are the ones the input asked for.
3. **Wiring** — the vault points at its own access manager, price manager and
   rewards manager; the withdraw manager and the fee manager point back at the
   vault; the vault base is the one the factory itself reports; the withdraw
   window equals the factory's configured window.
4. **Authorization and fees** — the requested owner holds `OWNER_ROLE` with no
   execution delay, the redemption delay is the requested number of seconds, the
   DAO management fee, performance fee and recipient are the expected package's,
   and the vault pays into the fee manager's own fee accounts at the rates that
   manager reports.

A simulation whose creation succeeded but whose state fails a check is reported
with status `unverified`, not `success`. Wiring values are compared against other
values read from the same chain rather than against constants written into the
tooling, so a future deployment with a different withdraw window or vault base
does not need the rules edited to keep passing.

## Resolving a real creation from its receipt

A transaction receipt does not carry the return value of a Solidity call, so
nothing in this repository reads created addresses from one. `vault:verify`
resolves them from the factory's own event and from state:

```bash
npm run vault:verify -- --chain 1 --tx 0x… --json
npm run vault:verify -- --chain 1 --tx 0x… --config config/vaults/example.json
npm run vault:verify -- --chain 1 --tx 0x… --rpc-url http://127.0.0.1:8545   # a local fork
```

Exit codes: `0` the receipt was read — see `status` — `1` refused or not
resolvable, `2` bad arguments.

`status` distinguishes the outcomes that must never be confused with each other:

| Status       | Meaning                                                                     |
| ------------ | ---------------------------------------------------------------------------- |
| `success`    | Mined, successful, the creation event was found and the state agrees.        |
| `unverified` | Mined and successful, but a state check against `--config` failed.           |
| `reverted`   | Mined and failed. No vault exists — do not retry the creation blindly.       |
| `pending`    | Known to the endpoint, not yet in a block. Resending would create a second vault. |
| `not-final`  | Mined, but with fewer confirmations than `--min-confirmations` (default 1).  |

Refusals: `TRANSACTION_UNKNOWN` (the endpoint has never seen the hash),
`UNKNOWN_DEPLOYMENT` (the transaction targets an address the registry does not
know), `CREATION_EVENT_ABSENT`, `CREATION_EVENT_AMBIGUOUS` and
`FOREIGN_CREATION_EVENT` — the last one when the only event with the right
signature was emitted by some other contract. Foreign events are counted in
`result.foreignEventsIgnored` and never decoded as the result.

What the event gives (index, version, name, symbol, decimals, underlying, owner,
vault, vault base, fee manager) is completed by reading the vault: its access
manager, price manager and rewards manager. The withdraw manager has no getter on
the vault in this deployed version, so it is identified among the receipt's own
log emitters by asking each one which vault it belongs to. The context manager
cannot be resolved this way and is listed in `result.unresolved` rather than
guessed.

With `--config`, the same rules as the simulation run against the resolved
instance, so a real creation is held to the standard the simulated one was. One
check fewer runs here: the context manager's existence cannot be checked because
its address is not resolvable from the receipt.

## Configuring the ERC4626 pilot strategy

A vault created by the factory holds no strategy: no fuses, no substrates, no
market limits. `vault:configure` applies exactly one catalogued integration —
today `ethereum-erc4626-market-100001` — to one created vault, on a development
fork:

```bash
npm run vault:configure -- --config config/strategies/erc4626-usdc.json \
  --vault 0x… --rpc-url http://127.0.0.1:8545 --dry-run
npm run vault:configure -- --config config/strategies/erc4626-usdc.json \
  --vault 0x… --rpc-url http://127.0.0.1:8545 --json
```

Exit codes: `0` configured (or planned with `--dry-run`), `1` refused, `2` bad
arguments or an unreadable file.

The input ([schema](../config/strategies/strategy-configuration.schema.json),
[example](../config/strategies/erc4626-usdc.json)) names the catalog entry, the
four operator addresses, the market's limit as a WAD fraction of the vault's
assets (`1000000000000000000` is 100%, and it is a decimal string because the
value does not fit a JSON number safely), the ERC4626 vaults allowed as substrates, and the assets the balance fuse has to price.

Four steps run, each as the operator that holds the role for it:

| Step               | Operator      | Role                | What it does                                          |
| ------------------ | ------------- | ------------------- | ------------------------------------------------------ |
| `grant-roles`      | owner         | `OWNER_ROLE`        | grants `ATOMIST_ROLE`, `FUSE_MANAGER_ROLE`, `ALPHA_ROLE` |
| `register-fuses`   | fuse manager  | `FUSE_MANAGER_ROLE` | `addFuses` and `addBalanceFuse` for the market          |
| `grant-substrates` | fuse manager  | `FUSE_MANAGER_ROLE` | `grantMarketSubstrates` with exactly the listed vaults  |
| `set-limits`       | atomist       | `ATOMIST_ROLE`      | `setupMarketsLimits` and `activateMarketsLimits`        |

Refusals, all before or instead of changing anything:

| Error                       | Cause                                                                       |
| --------------------------- | ---------------------------------------------------------------------------- |
| `UNKNOWN_INTEGRATION`       | `catalogId` is not in the catalog.                                            |
| `MARKET_MISMATCH`           | The config's market is not the integration's market.                         |
| `UNVERIFIED_FUSE`           | The catalogued fuse deployment was not observed on chain.                    |
| `SUBSTRATE_ASSET_MISMATCH`  | A substrate ERC4626 vault is denominated in another asset than the vault's.  |
| `SUBSTRATE_NOT_ERC4626`     | A substrate does not answer `asset()`.                                        |
| `PRICE_SOURCE_MISSING`      | The vault's price manager cannot price an asset the balance fuse needs.      |
| `MISSING_ROLE`              | The operator for a step does not hold its role.                              |
| `NOT_A_FORK`                | The endpoint does not allow impersonation, so it is not a development fork.  |
| `CONFIGURATION_NOT_APPLIED` | The steps ran but the vault does not report the configuration back.          |

After the steps, the tool reads the configuration back from the vault — the
registered fuse, the granted substrates, the market limit and the alpha's role.
A step that succeeded without changing anything is not accepted as configured.

On a real network these four steps are four transactions signed by the role
holders; the tool impersonates them, which only a local fork allows.

## Preflight: revalidating a plan before execution

A plan is a statement about one block. `vault:preflight` checks whether it still
holds now, and re-simulates it at the state it just read:

```bash
npm run vault:preflight -- --plan plan.json
npm run vault:preflight -- --plan plan.json --max-age-blocks 300 --json
npm run vault:preflight -- --plan plan.json --block 25937526 --skip-simulation
```

Exit codes: `0` **go**, `1` **stop** (or the preflight could not complete), `2`
bad arguments.

Eleven checks run, each comparing the artifact against the chain or the
repository:

| Check                     | Stops the plan when…                                                    |
| ------------------------- | ------------------------------------------------------------------------ |
| `input.unchanged`         | the configuration file no longer hashes to what the plan recorded.       |
| `manifest.verified`       | the deployment is no longer `verified` in the registry.                  |
| `chain.id`                | the provider serves another chain.                                       |
| `plan.age`                | the plan is older than `--max-age-blocks` (only when that flag is given).|
| `identity.implementation` | the proxy points at another implementation.                              |
| `identity.version`        | the factory reports another version.                                     |
| `identity.components`     | a factory or base component address recorded in the verification report changed. |
| `caller.shape`            | the caller now has code, so the simulated EOA path no longer describes it. |
| `fees.source`             | the caller now resolves to the other package list.                       |
| `fees.values`             | the selected package charges different fees.                             |
| `fees.recipient`          | the package pays a different recipient.                                  |
| `fees.index`              | the planned index no longer exists in that list.                         |
| `simulation.current`      | re-simulating at the state just read no longer succeeds and verifies.    |

### The risk a "go" does not remove

The report carries this in `residualRisk`, and it is not a formality:

- State can change between the preflight and the block the transaction is
  actually included in. The factory offers no way for a caller to require an
  implementation, a version or a fee package **atomically** as part of the
  creation call, so nothing on chain rejects a creation that lands after an
  upgrade or a fee change.
- A "go" is a statement about the state read at the reported block, not a
  guarantee about execution.
- A path that changes `msg.sender` — a Safe or a helper contract — resolves
  different fee packages and needs its own plan and its own preflight.

Shortening the window between preflight and execution reduces that exposure; it
does not remove it. Anything stronger would need a wrapper contract that checks
those values in the same transaction, which is a separate design with its own
tests — and it changes the `msg.sender` the factory sees.

## The execution journal

A creation that is sent and then loses its answer is the one situation where
guessing costs a second vault. `vault:journal` keeps that decision out of the
tooling by writing down what was prepared and what happened to it:

```bash
npm run vault:journal -- record --plan plan.json          # state: prepared, records the sender's nonce
npm run vault:journal -- sent --id <id> --tx 0x…          # state: pending
npm run vault:journal -- sent --id <id> --no-response     # state: unknown — the send left, the answer did not come back
npm run vault:journal -- sync --id <id>                   # resolve against the chain
npm run vault:journal -- list
```

Exit codes: `0` done or settled, `1` refused or still unresolved, `2` bad
arguments. Entries live under `.fusion/journal/` (git-ignored, override with
`FUSION_JOURNAL_DIR`) and carry the plan's SHA-256, the deployment, the sender,
the target, a hash of the calldata, **the sender's nonce**, the transaction hash
once known, and the full state history.

| State       | Meaning                                                                 |
| ----------- | ------------------------------------------------------------------------ |
| `prepared`  | The plan and the nonce are recorded; nothing was sent.                   |
| `pending`   | A hash is known and the transaction is not mined yet.                    |
| `unknown`   | The send left without a usable answer. Resolve it; never resend blindly. |
| `confirmed` | Mined successfully; the receipt's block and gas are recorded.            |
| `reverted`  | Mined and failed; no vault exists.                                       |

Two rules do the work:

- **`record` refuses** with `DUPLICATE_IN_FLIGHT` while an entry for the same
  plan and sender is not settled. Preparing another send is exactly how a
  duplicate vault gets created.
- **`sync` on an entry with no hash** compares the sender's nonce with the one
  recorded. If the nonce is unused, nothing was mined and the tool says so
  instead of deciding. If it was used, the journal searches recent blocks for
  the transaction with that nonce and settles from its receipt — and if it
  cannot find it, it says that too, and tells you to widen the search rather
  than to resend.

Once settled, `sync` prints the `vault:verify` command that resolves the created
addresses from the receipt.

## Executing an approved plan (EOA)

`vault:execute` is the one path in this repository that sends a transaction. It
does nothing of its own: it revalidates, records, sends the plan's calldata
verbatim, and settles the journal entry from the chain.

```bash
# on a local fork, with an impersonated sender
npm run vault:execute -- --plan plan.json --scope config/execution/scope.example.json \
  --fork-unlocked --rpc-url http://127.0.0.1:8545

# with a real signer: a Foundry keystore account, never a key on the command line
cast wallet import pilot-sender --interactive     # once, outside this repository
npm run vault:execute -- --plan plan.json --scope config/execution/scope.example.json \
  --account pilot-sender --password-file /path/outside/the/repo
```

Exit codes: `0` sent and settled, `1` refused or unresolved, `2` bad arguments.

### Where the key is, and where it never is

- The private key lives in a **Foundry keystore account**. `cast` is invoked with
  the account *name*; the key never becomes a process argument, which other users
  on the machine can read.
- `--private-key`, `--mnemonic` and `--interactive` are **rejected** by this tool
  with `KEY_IN_ARGUMENT` before anything else happens.
- Nothing about the signer reaches the journal, the reports or the terminal: the
  journal stores a hash of the calldata, the sender's address and its nonce.

### The scope is the authorization

[`config/execution/scope.example.json`](../config/execution/scope.example.json)
states what may be sent at all: the chain, the allowed target addresses, the
allowed function selectors, the allowed senders, the maximum value and a gas
cap. A plan outside any of those is refused with `OUT_OF_SCOPE` and **no journal
entry is created** — a refusal is not an attempt.

Approval is per plan and per scope, not per session: the tool reads the plan file
it is given and sends that file's calldata unchanged. It never rebuilds calldata
and never substitutes a value.

### Order of operations

1. **Scope check** — before any network access.
2. **Preflight** ([above](#preflight-revalidating-a-plan-before-execution)) — a
   stop means nothing is sent and nothing is recorded.
3. **Journal `record`** — the intent and the sender's nonce, before the send.
4. **`cast send`** with the plan's calldata; on any failure the entry is set to
   `unknown` and you are told to `sync` it rather than to run the command again.
5. **Journal `sync`** — the outcome is read from the chain, not from the send's
   own answer.

## Creating through a Safe

A Safe calling the factory is a different caller than the owner EOA, and the
factory picks fees by `msg.sender`. `vault:safe` therefore resolves the fees for
the **Safe's own address**, exports the call as a Safe Transaction Builder batch,
and simulates the Safe as the direct caller:

```bash
npm run vault:safe -- --plan safe-plan.json --compare-with 0x<owner eoa> --out batch.json
npm run vault:safe -- --plan safe-plan.json --json
```

Exit codes: `0` exported and simulated successfully, `1` refused or the
simulation reverted, `2` bad arguments.

The plan must be built with the Safe as `caller` — a plan whose caller has no
code is refused with `CALLER_NOT_A_CONTRACT`, because exporting an EOA's plan for
a Safe would silently change who the factory sees.

`--compare-with` resolves the same package index for another address, usually the
owner EOA, and reports every field that differs: the list (`dao-global` versus
`business-client`), both fee rates and the recipient. For the pilot Safe
(`0xF6a9bd8F…5569`) at block `25937526` both resolve to the same global package —
the report says so rather than staying silent, and it would name the differences
if there were any.

What the export is and is not:

- The batch is a **file to import into the Safe UI**. Nothing is proposed,
  signed or published to any Safe service.
- The simulation impersonates the Safe address, so `msg.sender` is the Safe. It
  does **not** run the Safe's own signature threshold or `execTransaction` logic;
  it answers the question the factory cares about, which is who calls it.
- No wrapper contract is deployed or suggested. A wrapper would change
  `msg.sender` again and resolve a third set of fees.

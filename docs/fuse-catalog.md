# Integration catalog

[`catalog/fuses.json`](../catalog/fuses.json) describes what a market of one
integration needs, in a form both people and tools can read. The schema is
[`catalog/fuses.schema.json`](../catalog/fuses.schema.json) and the entries are
checked against this checkout:

```bash
npm run validate:catalog
```

The catalog is not a deployment registry. Addresses of factories and vaults live
in [`deployments.md`](deployments.md); the catalog records which fuse contracts
were **observed** for a market and how strong that evidence is.

## What one entry holds

| Group             | Content                                                                                                                                                                                        |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `market`          | Market ID and the Solidity constant it comes from, or `origin` when no constant exists and the id is a constructor argument.                                                                   |
| `source`          | Primary action fuse and balance fuse in this checkout (`balanceFuse: null` when the integration has none).                                                                                     |
| `interface`       | `enter`/`exit`/`claim` signature, selector, struct name and the meaning of every field of the primary action fuse. `struct: null` means the function takes plain parameters, listed as fields. |
| `additionalFuses` | Every further fuse of the integration — other action fuses, reward claim fuses — each with its own `interface`, generated data and deployment evidence.                                        |
| `substrates`      | Their shape, what they mean, how they are granted and checked, and which ones were verified on chain.                                                                                          |
| `valuation`       | What the balance fuse prices, through which source, in which unit.                                                                                                                             |
| `roles`           | Which role executes, registers fuses, grants substrates, sets limits and price sources.                                                                                                        |
| `tests`           | The suites that exercise the integration.                                                                                                                                                      |
| `deployments`     | Observed fuse deployments with their block, code hash and market ID.                                                                                                                           |

Editorial text (what a field _means_) and observations (what was _read_) are kept
apart on purpose, and so is the structure of the code itself.

## Generated structure

`interface.generated` — on the integration for its primary fuse and on every
`additionalFuses` entry — is produced from the Solidity sources and is the only
part of an entry a tool writes:

```bash
npm run catalog:generate    # rewrite interface.generated from the sources
npm run catalog:check       # fail if the catalog no longer matches them
```

It carries, per fuse: the struct name (or `null`), canonical signature and
selector of every described operation, the `file:line` of the struct or
function and of every field, the `file:line` of the market constant, and the
SHA-256 of the fuse sources. Nested structs, enums, contract types and
user-defined value types are resolved through the fuse's imports and the
remappings in `foundry.toml`, so `PoolKey poolKey` becomes
`(address,address,uint24,int24,address)` in the signature while the field
keeps its declared type. When the compiler artifact of a fuse is present under
`out/`, `validate:catalog` also requires each selector to be one the compiled
contract emits.

The generator writes that subtree and nothing else: field meanings, substrate
semantics, valuation, roles, tests and observed deployments survive untouched.
Regenerating twice produces the same bytes; changing a struct in Solidity changes
the signature, the selector and the field list, and `catalog:check` then fails
until the catalog is regenerated and the meanings are updated.

`validate:catalog` compares the two halves: a described field list that no longer
matches the struct, or a described signature that no longer hashes to the
generated selector, is an error rather than silently stale documentation.

## Evidence levels

Each deployment carries a `status`:

- `observed` — read on chain at the stated block; the block, runtime code hash
  and the `MARKET_ID()` it reported are recorded;
- `unverified` — the address came from a source but was not read; it must not
  carry observation data;
- `unknown` — no address was found; `addressSource` says which registry and
  chain were searched, and `address` is `null`;
- `absent` — known not to exist.

`matchesCurrentSource` is separate again, and `null` means _not established_.
Nothing in the catalog claims a deployment is the code in this checkout unless
that was proven.

The validator enforces those rules: an `observed` entry needs its block, code
hash and market ID, an entry cannot claim to match the current source without
having been observed, the market constant must still hold the catalogued value,
every path must exist, and each selector must be the hash of its own signature.

## Entries

One row per catalogued integration market. `Evidence` summarises the
deployment status of the primary action fuse / balance fuse on the entry's
chain; the entry itself carries the block, code hash and notes.

| Entry id                                         | Chain    | Market                           | Primary fuse                            | Additional fuses                                                         | Evidence                              |
| ------------------------------------------------ | -------- | -------------------------------- | --------------------------------------- | ------------------------------------------------------------------------ | ------------------------------------- |
| `ethereum-erc4626-market-100001`                 | Ethereum | 100001 `ERC4626_0001`            | `Erc4626SupplyFuse`                     | –                                                                        | observed / observed                   |
| `ethereum-curve-stableswap-ng-market-16`         | Ethereum | 16 `CURVE_POOL`                  | `CurveStableswapNGSingleSideSupplyFuse` | –                                                                        | observed / observed                   |
| `ethereum-compound-v3-market-2`                  | Ethereum | 2 `COMPOUND_V3_USDC`             | `CompoundV3SupplyFuse`                  | CompoundV3ClaimFuse                                                      | observed / observed                   |
| `ethereum-compound-v3-market-13`                 | Ethereum | 13 `COMPOUND_V3_USDT`            | `CompoundV3SupplyFuse`                  | CompoundV3ClaimFuse                                                      | observed / observed                   |
| `base-compound-v3-market-26`                     | Base     | 26 `COMPOUND_V3_WETH`            | `CompoundV3SupplyFuse`                  | CompoundV3ClaimFuse                                                      | observed / observed                   |
| `ethereum-morpho-market-14`                      | Ethereum | 14 `MORPHO`                      | `MorphoSupplyFuse`                      | MorphoBorrowFuse, MorphoCollateralFuse, MorphoSupplyWithCallBackDataFuse | observed / observed (older)           |
| `ethereum-morpho-flash-loan-market-19`           | Ethereum | 19 `MORPHO_FLASH_LOAN`           | `MorphoFlashLoanFuse`                   | –                                                                        | observed / observed (ZeroBalanceFuse) |
| `ethereum-morpho-liquidity-in-markets-market-41` | Ethereum | 41 `MORPHO_LIQUIDITY_IN_MARKETS` | `MorphoSupplyFuse`                      | –                                                                        | observed / observed                   |
| `ethereum-morpho-rewards-market-22`              | Ethereum | 22 `MORPHO_REWARDS`              | `MorphoClaimFuse`                       | –                                                                        | observed / –                          |

## The pilot entry

`ethereum-erc4626-market-100001` documents the generic ERC4626 integration on
market `100001` (`ERC4626_0001`), with
[`Erc4626SupplyFuse.sol`](../contracts/fuses/erc4626/Erc4626SupplyFuse.sol) and
[`Erc4626BalanceFuse.sol`](../contracts/fuses/erc4626/Erc4626BalanceFuse.sol).

Two facts in it are worth reading before using those addresses:

- The substrate checked by both fuses is the **ERC4626 vault address**, even
  though the action fuse's file comment calls substrates "assets".
- The deployed balance fuse `0x2C10C360…` answers `MARKET_ID()` with `100001`
  but reverts on `VERSION()`, which this checkout's balance fuse exposes. It is
  therefore an older version of that fuse, and the catalog says so instead of
  presenting it as the current one.
- The deployed **supply** fuse `0x12FD0EE1…` is older too, and in a way that
  changes how it is called: its runtime code contains `enter((address,uint256))`
  `0xd5ee7916` and `exit((address,uint256))` `0x92876ac8`, while this checkout's
  structs carry a third field (`minSharesOut` / `maxSharesBurned`). Encoding the
  catalogued `interface` against that deployment reverts.

That last point is the reason the two halves of an entry are separate.
`interface` describes the code **in this checkout**, generated from it and kept
honest by `catalog:check`. `deployments` describes what is **on chain**, and its
`matchesCurrentSource: false` is the warning that the two are not the same
program. Before encoding a call to a deployed fuse, check the deployment's notes
— or probe the selectors in its runtime code, as the pilot lifecycle test does.

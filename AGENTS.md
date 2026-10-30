# AGENTS.md

Operating guide for AI agents (and humans) working in the `IPOR-Labs/ipor-fusion` repository.
Read this file first, then [`llms.txt`](./llms.txt) for the reading order and
[`ARCHITECTURE.md`](./ARCHITECTURE.md) for the contract map.

## Purpose

IPOR Fusion is an on-chain asset-management framework. Each **Plasma Vault** is an ERC-4626 vault whose assets are
moved into external protocols (Aave, Morpho, Euler, Pendle, …) through small adapter contracts called **fuses**.

- An **Atomist** (usually a multisig) configures a vault: fuses, markets, substrates, oracle, fees, limits.
- An **Alpha** (usually a bot) runs the strategy by calling `PlasmaVault.execute(FuseAction[])` within those limits.
- **Balance fuses** report each market's value in USD, which drives `totalAssets()` and the share price.

This repo holds the Solidity contracts and their Foundry tests. ABIs and deployed addresses live in
[`IPOR-Labs/ipor-abi`](https://github.com/IPOR-Labs/ipor-abi). User and integrator docs live at
[ipor.io/docs](https://ipor.io/docs/llms.txt).

## Directory map

| Path                                                | What is there                                                                                                                                                                                                                                                                                                                        |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `contracts/vaults/`                                 | `PlasmaVault` (ERC-4626 core, `execute`, fallback router), `PlasmaVaultBase` (ERC-20), `PlasmaVaultGovernance` (Atomist config), plugins, wrapped/whitelist extensions. See `contracts/vaults/README.md`.                                                                                                                            |
| `contracts/fuses/`                                  | One folder per protocol. Each has action fuses (`*SupplyFuse`, `*BorrowFuse`, …), a `*BalanceFuse`, and often a `*SubstrateLib` and a `README.md`. Shared interfaces: `IFuse.sol`, `IFuseCommon.sol`, `IMarketBalanceFuse.sol`, `IFuseInstantWithdraw.sol`. Chain-specific fuses: `contracts/fuses/chains/<chain>/`.                 |
| `contracts/rewards_fuses/`                          | Fuses that claim protocol rewards, run through `RewardsClaimManager`.                                                                                                                                                                                                                                                                |
| `contracts/managers/`                               | `access/` (`IporFusionAccessManager`, timelocks, redemption delay), `withdraw/` (`WithdrawManager`, scheduled withdrawals), `fee/`, `rewards/`, `price/` (`PriceOracleMiddlewareManager`), `context/` (`ContextManager`, signed calls on behalf of a user), `pause/` (`PlasmaVaultPauser`, emergency pause by whitelisted accounts). |
| `contracts/crosschain/`                             | Cross-chain transport for vault assets: `ccip/` (Chainlink CCIP) and `stargate/` (Stargate/LayerZero) executors, dispatchers and factories, plus shared `common/`, `interfaces/`, `lib/`. Each transport has a `README.md`. Vault-side fuses are in `contracts/fuses/crosschain/`.                                                   |
| `contracts/vendor/`                                 | Vendored third-party Solidity (LayerZero, Stargate, solady, solidity-bytes-utils) used by the crosschain code, with `CHECKSUMS.sha256` and `verify.sh`. See `contracts/vendor/README.md`.                                                                                                                                            |
| `contracts/safe-harbor/`                            | `SafeHarborRegistrar`: per-vault opt-in to the SEAL Safe Harbor agreement. See its `README.md`.                                                                                                                                                                                                                                      |
| `contracts/price_oracle/`                           | `PriceOracleMiddleware` (USD prices for assets) and price feeds (`price_feed/`).                                                                                                                                                                                                                                                     |
| `contracts/factory/`                                | `FusionFactory` clones a full vault stack (vault, access manager, managers) in one call. Price-feed factories in `factory/price_feed/`.                                                                                                                                                                                              |
| `contracts/handlers/`                               | `callbacks/` (flash-loan callback handlers for Morpho, Euler) and `pre_hooks/` (checks that run before vault methods).                                                                                                                                                                                                               |
| `contracts/libraries/`                              | `Roles.sol` (all role IDs), `IporFusionMarkets.sol` (all market IDs), `PlasmaVaultStorageLib.sol` (ERC-7201 storage), `PlasmaVaultConfigLib.sol` (substrates), `FusesLib.sol`, `math/IporMath.sol`, `errors/Errors.sol`.                                                                                                             |
| `contracts/transient_storage/`                      | `TransientStorageLib`, used by the `enterTransient`/`exitTransient` fuse variants to chain fuse outputs into inputs.                                                                                                                                                                                                                 |
| `contracts/readers/`, `contracts/universal_reader/` | Read-only helpers for off-chain tooling.                                                                                                                                                                                                                                                                                             |
| `test/`                                             | Foundry tests. Mirrors `contracts/` (`test/fuses/<protocol>/`, `test/vaults/`, `test/factory/`, …). Helpers in `test/test_helpers/` and `test/utils/`.                                                                                                                                                                               |
| `lib/`                                              | Git submodule: `forge-std`.                                                                                                                                                                                                                                                                                                          |
| `node_modules/`                                     | Solidity dependencies (OpenZeppelin 5.0.2, Uniswap, Pendle, Chainlink, Morpho, EVC) and lint tools. Required for `forge build`.                                                                                                                                                                                                      |

## Setup

Requirements: [Foundry](https://getfoundry.sh/), Node.js 20.17.0 / npm 10.8.2 (see `package.json` `engines`),
Python 3.11 only if you use pre-commit.

```bash
git submodule update --init --recursive   # forge-std
npm ci                                    # Solidity deps + solhint + prettier
```

- `foundryup` installs `forge` into `~/.foundry/bin`. If `forge` is not found, call `~/.foundry/bin/forge` or add
  that folder to `PATH`.
- Fork tests need a `.env` file with RPC URLs (see "Environment variables" below). The repo has no
  `.env.example` any more, so create `.env` by hand. Skip this if you only run mock tests: they need no RPC.

## Build, test, lint

| Task                     | Command                                                                       | Needs RPC?           |
| ------------------------ | ----------------------------------------------------------------------------- | -------------------- |
| Build                    | `forge build`                                                                 | No                   |
| Contract sizes           | `forge build --sizes --skip test --skip script`                               | No                   |
| All tests (what CI runs) | `forge test -vvv`                                                             | Yes, all five chains |
| One folder, mocks only   | `forge test --match-path 'test/fuses/aave_v4/*' --no-match-path '*Fork*' -vv` | No                   |
| One test function        | `forge test --match-test testShouldBeAbleToSupply -vvv`                       | Depends on the test  |
| Lint                     | `npm run solhint:all`                                                         | No                   |
| Format                   | `npm run prettier:all` (writes files)                                         | No                   |

A filtered run compiles only what it needs: the Aave V4 mock-test command above takes about 45 seconds from a clean
checkout. A full `forge build` compiles everything and takes longer. Later runs are incremental. Build output goes
to `out/` and `cache/` (both gitignored); pass `--out <dir> --cache-path <dir>` to keep the checkout untouched.

`foundry.toml` sets `ffi = true` and `isolate = false`. Keep `isolate = false`: fuse tests write transient-storage
inputs in one call and read them in the next, and isolation clears transient storage between calls.
The `crosschain_deploy` profile pins linked-library addresses for crosschain deployments; tests use the default
profile.

CI (`.github/workflows/smart-contracts-build.yml`) runs, in order: `forge build`, `forge test -vvv`,
`npm run solhint:all`, `npm run prettier:all`. Run Prettier locally and commit its changes before opening a PR.

### Environment variables

RPC URLs are read with `vm.envString(...)` from `.env`:

| Variable                    | Chain            | Used by                         |
| --------------------------- | ---------------- | ------------------------------- |
| `ETHEREUM_PROVIDER_URL`     | Ethereum mainnet | Most fork tests (CI)            |
| `ARBITRUM_PROVIDER_URL`     | Arbitrum One     | Arbitrum fork tests (CI)        |
| `BASE_PROVIDER_URL`         | Base             | Base fork tests (CI)            |
| `TAC_PROVIDER_URL`          | TAC              | TAC fork tests (CI)             |
| `INK_PROVIDER_URL`          | Ink              | Ink fork tests (CI)             |
| `HYPEREVM_MAINNET_FORK_RPC` | HyperEVM         | One HyperEVM fork test (not CI) |

Use **archive** RPC endpoints. Fork tests pin historical blocks.

### Fork tests and mock tests

- **Fork tests** (about 210 files) call
  `vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), <block>)` in `setUp()` (directly or through a base
  contract such as `AaveV4ForkTestBase`) and run against real protocol state at a pinned block. Without the
  matching env var they fail in `setUp`. Many are named `*ForkTest.t.sol`.
- **Mock tests** (about 320 files) need no RPC. They deploy the fuse plus mocks (for example
  `test/fuses/PlasmaVaultMock.sol`, `test/test_helpers/MockErc4626.sol`). Good first targets: the non-fork files
  in `test/fuses/aave_v4/`, `test/fuses/transient_storage/`, `test/libraries/`.

To list test files that do not fork directly (check the base contract too, since some inherit a fork):

```bash
grep -rL -e createSelectFork -e createFork --include='*.t.sol' test
```

## Coding conventions

- Compiler: `pragma solidity 0.8.30;` (exact, no caret). EVM `cancun` (`arbitrum` profile uses `paris`).
- License header: `// SPDX-License-Identifier: BUSL-1.1` for `contracts/`. Tests usually use `UNLICENSED`.
- Imports: named imports with relative paths (`import {IFuseCommon} from "../IFuseCommon.sol";`). Remappings live
  in `foundry.toml`.
- Naming: function parameters end with `_` (`marketId_`). Immutables and constants are `UPPER_CASE`
  (`MARKET_ID`, `VERSION`). Fuse structs are `<Fuse>EnterData` / `<Fuse>ExitData`.
- Errors: custom errors prefixed with the contract name (`Erc4626SupplyFuseUnsupportedVault`). No revert strings.
- Events: emit on every state-changing action, include `VERSION` (the fuse address) as the first argument.
- NatSpec on every public/external function and struct field.
- Formatting: Prettier with `prettier-plugin-solidity` (`.prettierrc.js`). Lint: solhint (`.solhint.json`).
- Tests: `contract <Name>Test is Test`, test names `testShould...` / `testShouldRevertWhen...`, bodies split with
  `// given`, `// when`, `// then` comments.

## Developing a fuse (checklist)

Reference implementation: `contracts/fuses/erc4626/Erc4626SupplyFuse.sol` + `Erc4626BalanceFuse.sol`.
Full guide: [Developing a Fuse](https://ipor.io/docs/build-on-fusion/developer-guide/developing-a-fuse.md) and
[Integrating a New Market](https://ipor.io/docs/build-on-fusion/integrating-a-new-market.md).

1. **Market ID.** Add a new constant to `contracts/libraries/IporFusionMarkets.sol`. Never reuse or change an
   existing value. If the market depends on another market's balance (for example swaps change
   `ERC20_VAULT_BALANCE`), say so in the NatSpec comment.
2. **Action fuse.** Implements `IFuseCommon` (`MARKET_ID()`), with `enter(<X>EnterData)` and `exit(<X>ExitData)`.
   Set `VERSION = address(this)` and `MARKET_ID` as immutables in the constructor.
3. **Stateless.** The vault calls fuses with `delegatecall`, so fuse code runs in the vault's storage.
   Only immutables and constants. No storage variables. If you need storage, use an ERC-7201 namespaced library.
4. **Substrate checks.** Every `enter`/`exit` checks that the target asset/vault/pool is granted for `MARKET_ID`
   (`PlasmaVaultConfigLib.isSubstrateAsAssetGranted` or a typed `*SubstrateLib`). Revert if not.
5. **Limits on every action.** Cap amounts to the available balance, add slippage guards (`minSharesOut`,
   `maxSharesBurned`, …), use `forceApprove` and leave no allowance behind.
6. **Optional variants.** `enterTransient()`/`exitTransient()` (read inputs, write outputs via
   `TransientStorageLib`), and `instantWithdraw(bytes32[] params)` (`IFuseInstantWithdraw`, `params[0]` is the amount
   in underlying; wrap the external call in try/catch and emit a `*ExitFailed` event instead of reverting, so one
   failing market does not block user withdrawals).
7. **Balance fuse.** Implements `IMarketBalanceFuse.balanceOf()`, returns the vault's net position in USD,
   18 decimals (WAD), priced through `PlasmaVaultLib.getPriceOracleMiddleware()`. It must never return a silently
   wrong value: revert on negative balances or missing prices.
8. **Tests.** Add `test/fuses/<protocol>/`. Cover enter, exit, substrate rejection, slippage reverts, the balance
   fuse, and instant withdraw if implemented. Fork tests pin a block; mock tests use `PlasmaVaultMock`.
9. **README.** Add `contracts/fuses/<protocol>/README.md` with the sections the other fuse READMEs use: Overview,
   Market Structure, Architecture, Balance Calculation, Substrate Configuration, Price Oracle Setup, Security
   Considerations.
10. **Gate.** `forge build`, the new tests, `npm run solhint:all` and `npm run prettier:all` all pass.

On-chain, a new fuse is used by a vault only after it is listed in the `FuseWhitelist` registry
(`contracts/fuses/whitelist/`) and the Atomist adds it with `addFuses` / `addBalanceFuse` and grants substrates.

## Hard rules

- **Never change the storage layout of upgradeable or cloned contracts.** Vaults and managers are clones/proxies
  using ERC-7201 namespaced storage (`PlasmaVaultStorageLib`, `*StorageLib.sol`). Do not rename namespace strings,
  reorder or remove struct fields, or change slot constants. Add new fields only at the end of a struct or in a new
  namespace. `test/libraries/FusionStorageSlotsTest.t.sol` and `PlasmaVaultStorageLibSlotTest.t.sol` must stay green.
  UUPS contracts (`PriceOracleMiddleware`, `FuseWhitelist`, `FusionFactory`, wrapped-vault and price-feed factories)
  follow the same rule.
- **Never add storage variables to a fuse.** See the checklist, step 3.
- **Never change existing role IDs (`Roles.sol`) or market IDs (`IporFusionMarkets.sol`).** Deployed vaults
  depend on them.
- **Never commit secrets.** `.env`, RPC URLs with API keys, and private keys stay out of git. Never put a key in a
  test, script or comment. Tests use `vm.addr`/`makeAddr`, not real keys.
- **Never broadcast transactions.** Do not run `forge script --broadcast`, `cast send` or anything that signs or
  sends a transaction. Deployments and vault configuration go through the IPOR tooling and multisigs.
- **Never edit vendored code.** `contracts/vendor/` is upstream code pinned by `CHECKSUMS.sha256`; `verify.sh`
  fails on any change. Changes there need an explicit ticket and an updated manifest.
- **Crosschain linked libraries are pinned.** The `crosschain_deploy` profile in `foundry.toml` fixes the address
  of each crosschain library. Changing a library means re-pinning it and re-linking its hosts (see
  `contracts/crosschain/ccip/README.md`).
- **Treat fund-moving roles as critical.** Code paths reachable by these roles need extra review and tests:
    - `ALPHA_ROLE` (200): `PlasmaVault.execute` runs fuses with full vault context.
    - `FUSE_MANAGER_ROLE` (300): adds fuses and grants substrates, which decides where funds can go.
    - `PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE` (1200): sets prices, which sets the share price.
    - `ATOMIST_ROLE` (100), `OWNER_ROLE` (1), `ADMIN_ROLE` (0): grant all of the above.
    - `CLAIM_REWARDS_ROLE` (600), `TRANSFER_REWARDS_ROLE` (700), `CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE` (900),
      `UPDATE_MARKETS_BALANCES_ROLE` (1000).
- **Do not weaken access control.** Every external state-changing function on vaults and managers is
  `restricted` (OpenZeppelin `AccessManager`). Do not remove the modifier or add unrestricted entry points.
- **Share price must not move silently.** Any change to `totalAssets`, balance fuses, fees or the oracle must keep
  the rules in [General share price calculation rules](https://ipor.io/docs/build-on-fusion/developer-guide/general-share-price-calculation-rules.md).

## Where to find more

- Reading order for LLMs: [`llms.txt`](./llms.txt)
- Contract map and call flows: [`ARCHITECTURE.md`](./ARCHITECTURE.md)
- Vault internals: [`contracts/vaults/README.md`](./contracts/vaults/README.md)
- Per-protocol fuse notes: `contracts/fuses/<protocol>/README.md`
- Crosschain transports: [`contracts/crosschain/ccip/README.md`](./contracts/crosschain/ccip/README.md),
  [`contracts/crosschain/stargate/README.md`](./contracts/crosschain/stargate/README.md)
- ABIs and deployed addresses: [`IPOR-Labs/ipor-abi`](https://github.com/IPOR-Labs/ipor-abi), factory addresses at
  [Addresses](https://ipor.io/docs/build-on-fusion/developer-guide/addresses.md)
- Audits: [Security and Audits](https://ipor.io/docs/build-on-fusion/developer-guide/security-and-audits.md)

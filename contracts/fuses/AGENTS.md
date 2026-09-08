# Fuse contributor instructions

These instructions supplement the repository root `AGENTS.md` for
`contracts/fuses/`, `contracts/rewards_fuses/` and their subdirectories.

## Start here

- Read [`../../docs/architecture.md`](../../docs/architecture.md) for how the
  vault reaches a fuse and which address owns the storage that a fuse writes.
- Read [`../../docs/roles-and-permissions.md`](../../docs/roles-and-permissions.md)
  before touching who may execute a fuse or who may configure a market.
- Pick an existing integration close to the one you are changing and read it
  end to end before writing anything. Many integrations ship a `README.md` next
  to their sources; list them with `git ls-files 'contracts/**/README.md'`.

`contracts/fuses/erc4626/` is the smallest complete example and is used
throughout this document: [`Erc4626SupplyFuse.sol`](erc4626/Erc4626SupplyFuse.sol)
is the action fuse, [`Erc4626BalanceFuse.sol`](erc4626/Erc4626BalanceFuse.sol)
is its balance fuse, and `test/fuses/erc4626/` holds both suites.

## The four pieces of an integration

An integration is only complete when all four exist and agree on one market ID.

1. **Action fuse** — `enter`/`exit` against the external protocol. Implements
   [`IFuseCommon`](IFuseCommon.sol) and exposes `MARKET_ID`. `IFuse` declares the
   `bytes` form; most fuses instead expose ABI-typed `enter(<struct>)` and
   `exit(<struct>)`, which is what callers encode against.
2. **Balance fuse** — implements [`IMarketBalanceFuse`](IMarketBalanceFuse.sol)
   and returns the market's value in USD with 18 decimals. Use
   [`ZeroBalanceFuse.sol`](ZeroBalanceFuse.sol) only when the market genuinely
   holds no value of its own.
3. **Substrates** — what the market is allowed to touch, granted per market ID.
4. **Valuation inputs** — a price feed for every asset the balance fuse prices.

Optional, and only when the integration needs it:
[`IFuseInstantWithdraw`](IFuseInstantWithdraw.sol) for the withdraw path, an
`enterTransient`/`exitTransient` pair when the fuse is chained through
`transient_storage/`, and a `contracts/rewards_fuses/` claim fuse.

## How the vault calls a fuse

`PlasmaVault.execute(FuseAction[])` — see `contracts/vaults/PlasmaVault.sol` —
does the following per action, and each step is a constraint on your fuse:

1. rejects the action unless `FusesLib.isFuseSupported(fuse)`;
2. reads `IFuseCommon(fuse).MARKET_ID()` and collects the touched markets;
3. `functionDelegateCall`s the fuse with the raw `data` bytes;
4. after the loop, re-reads every touched market through its balance fuse and
   enforces the market limits in `AssetDistributionProtectionLib`.

Consequences to respect:

- The fuse runs under `delegatecall`. `address(this)` is the PlasmaVault, so the
  vault holds the tokens, receives the shares, and owns every storage slot the
  fuse writes. Never store fuse-local state outside a namespaced library.
- `FuseAction.data` is opaque bytes selected by the caller. Authorization comes
  from the vault's role check plus your own substrate check — not from the
  encoded data. Validate before moving funds.
- `MARKET_ID` is immutable and set in the constructor. Deploying the same fuse
  for another market means deploying another instance.
- `claimRewards(FuseAction[])` delegatecalls without the `isFuseSupported`
  check that `execute` performs. Reward fuses must not assume that guard.
- Making a market's balance move without the matching balance fuse being
  registered silently mis-prices the vault. Add both or neither.

## Substrates

Substrates are the per-market allowlist in
[`../libraries/PlasmaVaultConfigLib.sol`](../libraries/PlasmaVaultConfigLib.sol).
Every action fuse must check its inputs against them and revert with a named
error, as `Erc4626SupplyFuse` does on both `enter` and `exit`.

- Address-shaped substrates: grant with `grantSubstratesAsAssetsToMarket`, check
  with `isSubstrateAsAssetGranted`.
- Structured substrates: pack them into `bytes32` in a dedicated
  `<Protocol>SubstrateLib`, grant with `grantMarketSubstrates`, check with
  `isMarketSubstrateGranted`. See
  [`balancer/BalancerSubstrateLib.sol`](balancer/BalancerSubstrateLib.sol) for
  the type-tag-in-the-high-bits convention.
- Both grant functions **revoke every existing substrate of that market first**.
  A grant is a full replacement of the market's list, never an addition.
- Both check functions read the same mapping; the encoding is the only
  difference. Keep one convention per market ID so a packed substrate and a bare
  address cannot be confused.
- A packing change is a breaking change to every deployed configuration of that
  market. Treat it as such and say so in the handoff.

## Balance fuses and valuation

`balanceOf()` is reached by `delegatecall` from
`contracts/vaults/lib/PlasmaVaultMarketsLib.sol`, so it reads the vault's own
positions through `address(this)`.

- Return USD in WAD (18 decimals). Convert with `IporMath.convertToWad` and the
  asset decimals plus the oracle's price decimals, as `Erc4626BalanceFuse` does.
  Do not assume 8 or 18 decimals for either side.
- Prices come from `PlasmaVaultLib.getPriceOracleMiddleware()`. Every asset the
  fuse prices needs a configured feed, otherwise the whole `execute` reverts on
  the balance update, not on the action.
- Price the position from protocol accounting (`convertToAssets`, an accrued
  index, a protocol view), not from a spot reserve ratio that a swap can move
  within the transaction.
- One balance fuse per market ID: `FusesLib.addBalanceFuse` rejects a second one
  and rejects a fuse whose `MARKET_ID` does not match. `removeBalanceFuse`
  refuses while the market still holds more than dust.
- If a market's value depends on another market's balance, register the
  dependency with `PlasmaVaultLib.updateDependencyBalanceGraph`. The market ID
  comments in [`../libraries/IporFusionMarkets.sol`](../libraries/IporFusionMarkets.sol)
  record which markets already require this.

## Change checklist

1. Trace the whole path before editing: caller → `execute` → your fuse →
   external protocol → balance fuse → limit check.
2. Keep `enter`/`exit` struct layouts stable. Callers and tests encode them by
   signature — `test/fuses/PlasmaVaultMock.sol` uses literal strings such as
   `enter((address,uint256,uint256))` — so adding or reordering a field breaks
   every call site, including deployed alpha calldata.
3. Clamp amounts to what the vault actually holds or can withdraw instead of
   reverting on a rounding difference, and return early on a zero amount.
4. Set the spender allowance with `forceApprove` immediately before the external
   call. For a fuse that forwards arbitrary calldata, revoke it right after.
5. Enforce a caller-supplied slippage bound on every leg that produces or burns
   shares (`minSharesOut`, `maxSharesBurned`). A leg without one is a finding.
6. State units at the boundary: token smallest units, WAD, BPS, seconds. Say
   which direction each conversion rounds.
7. Keep the event shape stable and do not add `indexed` parameters; this
   repository deliberately keeps event parameters in the data section.
8. Do not change compiler settings and do not enable `via_ir`.

Refactoring an unrelated fuse is out of scope for an integration change. Note it
for a separate task instead.

## Tests

Mirror the source layout: a fuse under `contracts/fuses/<integration>/` is
tested by `test/fuses/<integration>/`, or `test/unitTest/fuses/<integration>/`
when a local suite exists. Reward fuses follow the same rule under `test/`.

Start from the smallest file that covers the changed contract, then widen to the
callers the change can reach — the balance fuse when accounting moves, the
withdraw path when `instantWithdraw` changes, and a full vault suite when the
market configuration itself changes.

Most fuse tests exercise the fuse through
[`../../test/fuses/PlasmaVaultMock.sol`](../../test/fuses/PlasmaVaultMock.sol),
which reproduces the production call shape: it `functionDelegateCall`s the fuse
and exposes `grantAssetsToMarket`, `grantMarketSubstrates`, `balanceOf` and
`setPriceOracleMiddleware`. Adding a fuse usually means adding its entry point
there. The mock keeps delegatecall semantics but has no roles, limits or fee
accounting — a change to those needs a real vault suite.

Walking the ERC-4626 example from source to test:

```bash
forge build
forge test --match-path 'test/fuses/erc4626/*'
```

Both files under `test/fuses/erc4626/` call
`vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), …)` at a pinned
block, so they need your own archive-capable provider. Foundry reads the ignored
`.env` in the repository root by itself, so no shell sourcing is required; an
already-exported variable takes precedence. Keep the pinned block unless the
task validates a new one, and report a missing provider or missing archive state
as an infrastructure limitation rather than as a protocol result.

Check `setUp()` and every helper before quoting a result. A fixture that deals
tokens, upgrades a proxy or grants roles is evidence for that mutated state, not
for an unchanged deployment.

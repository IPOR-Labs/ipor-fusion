# Vault contributor instructions

These instructions supplement the repository root `AGENTS.md` for
`contracts/vaults/` and its subdirectories.

## Start here

- Read [`../../docs/architecture.md`](../../docs/architecture.md) first. It
  holds the routing model, the storage-ownership map and verified call traces;
  this file does not repeat them.
- Read [`../../docs/roles-and-permissions.md`](../../docs/roles-and-permissions.md)
  before touching `restricted` functions, `_checkCanCall` or any initializer.
- Read [`../../docs/invariants.md`](../../docs/invariants.md) before changing
  accounting: it lists which properties a test asserts and which are only
  postulated.
- [`README.md`](README.md) in this directory is historical. Do not copy its
  fallback excerpt; the current router is in `PlasmaVault.sol`.

## What is here

- `PlasmaVault.sol` — the entry point every vault clone runs: ERC-4626 with
  overridden conversions, `execute`, `claimRewards`, the fallback router and
  `_checkCanCall`.
- `PlasmaVaultGovernance.sol` — abstract, every configuration getter and
  `restricted` setter. `PlasmaVault` does **not** inherit it.
- `PlasmaVaultBase.sol` — `is PlasmaVaultGovernance` plus ERC-20 permit, supply
  cap and votes propagation. It is a `delegatecall` target: the fallback sends
  every selector that `PlasmaVault` itself does not define to the base, unless
  `execute` is in progress (callback branch) or the selector is a votes
  function (plugin branch). Governance therefore runs in the clone's storage
  through the fallback, not through `PlasmaVault` code.
- `lib/PlasmaVaultFeesLib.sol` — internal fee math.
  `lib/PlasmaVaultMarketsLib.sol` — market balance refresh and the instant
  withdraw loop. Its functions are `public`, so it is a **linked library**
  deployed separately; `foundry.toml` declares no `libraries`, so a deploy must
  link it explicitly.
- `plugins/PlasmaVaultVotesPlugin.sol` — optional ERC-20 votes, reached by
  `delegatecall`, redeclaring OpenZeppelin namespaces so it writes the same
  slots the vault would. `ERC20VotesUpgradeable.sol` next to it is not on the
  live path; check before treating it as dead code.
- `initializers/IporFusionAccessManagerInitializerLibV1.sol` — builds the whole
  selector-to-role matrix for the vault and every manager. Fixed-size arrays
  sized by constants at the top of the file.
- `extensions/` — wrapper vaults around a PlasmaVault with their own fee
  accounting and `Ownable` or `AccessControl` gating. A fee change in the core
  vault does not propagate to them.

## Storage

Every slot the vault writes is an ERC-7201 namespace in
`contracts/libraries/PlasmaVaultStorageLib.sol`, `FuseStorageLib.sol`, the
OpenZeppelin parents, the votes plugin or an integration library. The clone
owns all of them; the implementation, base, plugin and fuse contracts are code
providers only.

- Never reuse a namespace or reorder a struct. Add new state as a new namespace
  and extend `test/libraries/PlasmaVaultStorageLibSlotTest.t.sol` (local), which
  recomputes the constants from their strings.
- `WITHDRAW_MANAGER_LEGACY_SLOT` is a pinned deployed-state value one byte away
  from `CALLBACK_HANDLER`. It is read only by the legacy fallback for two fee
  fuses; new code uses `getWithdrawManager().manager`.
- `EXECUTE_RUNNING` is ordinary storage, not transient. While it is set, the
  fallback returns empty bytes for every unmatched selector, so a governance or
  base call made re-entrantly from a fuse is a silent no-op.
- The plugin's copies of the `Votes`, `Nonces`, `EIP712` and `ERC20` namespaces
  are not covered by the slot tests. Nonces are shared between `permit` and
  `delegateBySig` on purpose.

## Accounting rules that are easy to break

- `totalAssets()` is **gross**: underlying balance plus cached market balances
  plus vested rewards. `_getNetTotalAssets()` subtracts the unrealized
  management fee and exists only as the performance-fee baseline. Previews and
  conversions ignore accrued, unrealized management fee.
- `_convertToShares` and `_convertToAssets` are overridden to use a stored share
  scale multiplier (`10 ** decimalsOffset`, set once at init). Do not reason
  with the stock OpenZeppelin virtual-shares formula and never assert exact
  round-trip equality; use a justified tolerance.
- Fee minting wraps `_mint` in `setTotalSupplyCapValidation(1)` and `(0)`. Any
  early return between the two leaves cap validation disabled; any new mint on
  that path bypasses the cap.
- `_realizeManagementFee` updates the fee timestamp only after a successful
  mint, and returns without updating it when the rounded share amount is zero.
  `PlasmaVaultFeesLib.prepareForRealizeManagementFee` deliberately does not
  touch the timestamp. Moving that write reintroduces a fee-suppression bug.
- Deposit-fee shares are minted to the **withdraw manager**, not to a fee
  account. Management and performance fee shares go to the fee accounts created
  by `FeeManagerFactory` from inside the vault initializer.
- The market cache is refreshed by `PlasmaVaultMarketsLib.updateMarketsBalances`:
  one oracle read for the underlying (reverts on a zero price), one balance-fuse
  `delegatecall` per touched market and its dependencies, then
  `AssetDistributionProtectionLib.checkLimits` against gross total assets.
  Limits are opt-in; the limit unit is checked by the fuse instructions and the
  ERC-4626 strategy recipe, not assumed here.
- `_redeem` retries `_withdrawFromMarkets` up to ten times with a default
  slippage allowance. The instant-withdraw loop never reverts on a shortfall; it
  stops, and the shortfall surfaces as an ERC-4626 max error or a failed
  transfer. `redeemFromRequest` skips the withdraw fee that `previewRedeem`
  already subtracts, and is `restricted` but not `nonReentrant`.

## Authorization inside the vault

- `_msgSender()` returns the context sender from `ContextClientStorageLib`,
  falling back to `msg.sender`. Signer, direct caller, context sender, share
  owner and receiver are five identities; `_checkCanCall` checks the receiver
  on `deposit` and `mint`, the owner on `withdraw` and `redeem`, and both owner
  and caller on `transferFrom`, each through the access manager's
  state-changing `canCallAndUpdate`, which is where the redemption lock is set
  and enforced. Other selectors use the read-only check and do not touch locks.
- `_runPreHook` is the last statement of `_checkCanCall` in both `PlasmaVault`
  and `PlasmaVaultBase`, so a pre-hook runs on every `restricted` call after
  authorization.
- `execute` and `executeInternal` reject a fuse that `FusesLib.isFuseSupported`
  does not know; `claimRewards` does not, and relies on `RewardsClaimManager`
  having checked its own fuse list. `executeInternal` is gated by
  `msg.sender == address(this)`, not by a role.
- Adding a governance function means: implement it in `PlasmaVaultGovernance`,
  add a `RoleToFunction` entry in the initializer and bump the matching
  `ROLES_TO_FUNCTION_*` constant, and confirm the selector is neither defined
  on `PlasmaVault` (which would shadow it) nor listed in `_isVotesFunction`
  (which would route it to the plugin and revert without one).

## Code size

Deployability cannot be judged from the default build. The default profile
compiles with ten million optimizer runs, which inflates code; the verified
deployments were compiled with 200 runs (see
[`../../docs/deployments.md`](../../docs/deployments.md)). Measured on this
checkout, runtime bytecode in bytes:

| Contract                 | default profile | 200 runs | EIP-170 limit |
| ------------------------ | --------------- | -------- | ------------- |
| `PlasmaVault`            | 31962           | 23908    | 24576         |
| `PlasmaVaultBase`        | 27264           | 21085    | 24576         |
| `PlasmaVaultVotesPlugin` | 7349            | 5802     | 24576         |
| `PlasmaVaultMarketsLib`  | 6426            | 5653     | 24576         |

`PlasmaVault` has a few hundred bytes of headroom at deployment settings. New
surface belongs in `PlasmaVaultBase`, a plugin or a linked library, not in
`PlasmaVault`. Re-measure with `FOUNDRY_OPTIMIZER_RUNS=200 forge build --out
<scratch dir>` before and after a change; do not edit `foundry.toml` and do not
enable `via_ir`. The CI size gate is disabled, so nothing else will catch it.

## Change checklist

1. Trace the path in `docs/architecture.md` before editing: which contract's
   code runs, in whose storage, with which `msg.sender`.
2. Keep every external selector, error, event layout and struct stable unless
   the task changes them; deployed alpha calldata and tooling encode against
   them. Event parameters stay non-`indexed`; a few existing events in
   `CallbackHandlerLib` and `ReferralPlasmaVault` are exceptions, not a licence.
3. A new namespace gets a slot test; a new manager address gets a cached slot
   and a setter; a new `restricted` selector gets an initializer entry.
4. State units at every boundary: underlying smallest units, shares with the
   decimals offset, USD in WAD from balance fuses, fee percentages in the unit
   of the manager that owns them (see
   [`../managers/AGENTS.md`](../managers/AGENTS.md)), seconds for delays.
5. Do not solve a vault problem by editing a wrapper in `extensions/`, or the
   reverse. They share struct types, not code.
6. Do not change compiler settings, and measure code size as described above.

## Tests and evidence

No vault suite is classified in `config/test-suites.json`, so `npm run test:unit`
does not run any of them and an unlisted suite carries no claim about being
local. `setUp()` is the only authority. As of this checkout:

- **Local (no RPC):** `test/vaults/PlasmaVaultErc4626ComplianceTest.t.sol`,
  `PlasmaVaultNonceTest.t.sol`, `PlasmaVaultVotesArchitectureTest.t.sol`,
  `PlasmaVaultVotesPluginTest.t.sol`, `VotesFunctionSelectorsTest.t.sol`,
  `BurnRequestFeeVotingRegressionTest.t.sol`, `lib/PlasmaVaultMarketsLibFilterTest.t.sol`,
  and the slot tests in [`../../test/libraries/`](../../test/libraries/).
- **Fork:** every other file in [`../../test/vaults/`](../../test/vaults/) and
  [`../../test/vaults/extensions/`](../../test/vaults/extensions/), pinned to
  Ethereum, Arbitrum or Base blocks named in each `setUp()`, plus
  [`../../test/pre_hooks/`](../../test/pre_hooks/) and
  `test/roles/IporPlasmaVaultRolesTest.t.sol`.

Map a change to its first suite: deposit and conversion math to
`PlasmaVaultDeposit.t.sol` and the compliance test; fees to `PlasmaVaultFee.t.sol`
and `PlasmaVaultDepositFee.t.sol`; withdraw paths to `PlasmaVaultWithdraw.t.sol`
and `PlasmaVaultScheduledWithdraw.t.sol`; market cache and limits to
`PlasmaVaultUpdateMarketsBalances.t.sol`; governance surface to
`PlasmaVaultMaintenance.t.sol`; callbacks to `PlasmaVaultCallbackHandler.t.sol`.
Shared fixtures live in `test/test_helpers/PlasmaVaultHelper.sol` and its
siblings; read what they grant and deploy before quoting a result.

A regression test for an accounting bug must reach the defective path through
the real vault, with separate addresses for caller, owner and receiver, and must
fail for the intended reason when the fix is reverted. Report a missing provider
or archive state as an infrastructure limitation.

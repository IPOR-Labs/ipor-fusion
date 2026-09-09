# Pilot invariants and the evidence for them

This page lists the properties the pilot path relies on — the vault created by
the deployed Ethereum FusionFactory, running the catalogued ERC4626 market — and
says, for each one, whether something in this repository actually checks it.

Two labels are used, and nothing in between:

- **tested** — a named test in this checkout exercises the property. The test is
  linked, and the rounding or tolerance it accepts is stated.
- **postulated** — the property is what the code is meant to guarantee, but no
  test in this checkout was found that pins it down for the pilot path. A
  postulated property is a gap, not a guarantee.

The pilot path is the one in [`recipes/create-vault.md`](recipes/create-vault.md)
and [`recipes/erc4626-strategy.md`](recipes/erc4626-strategy.md).

## Accounting and valuation

| #   | Property                                                                                     | Status     | Evidence                                                                                                                                                                                                    |
| --- | -------------------------------------------------------------------------------------------- | ---------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A1  | A deposit of `x` underlying leaves the vault's total assets unchanged by more than rounding. | tested     | [`Erc4626StrategyLifecycleEthereum.t.sol`](../test/deployed-factories/Erc4626StrategyLifecycleEthereum.t.sol) — `assertApproxEqAbs(totalAssets, 100000e6, 1e6)` after the deposit.                          |
| A2  | Moving funds from idle into the ERC4626 market does not change total assets.                 | tested     | Same test, asserted after the supply action with the same 1 USDC tolerance on 100 000 USDC.                                                                                                                 |
| A3  | Exiting the market returns the supplied amount to the vault, minus ERC4626 rounding.         | tested     | Same test: idle balance is back to ≈ the full deposit (±1 USDC).                                                                                                                                            |
| A4  | The idle balance drops by exactly the supplied amount.                                       | tested     | Same test: `assertEq(idle, deposit - supplied)` — exact, no tolerance.                                                                                                                                      |
| A5  | The balance fuse values the market in USD with 18 decimals, using the vault's price manager. | postulated | The unit is documented in [`Erc4626BalanceFuse.sol`](../contracts/fuses/erc4626/Erc4626BalanceFuse.sol) and the price source was checked to answer for USDC, but no pilot test asserts the returned figure. |
| A6  | Total assets track yield accruing in the external ERC4626 vault.                             | postulated | The pilot fork is pinned to one block, so entry and exit happen at the same share price. Nothing here demonstrates accrual.                                                                                 |
| A7  | The vault's ERC-4626 preview/max functions never revert.                                     | tested     | [`PlasmaVaultErc4626ComplianceTest.t.sol`](../test/vaults/PlasmaVaultErc4626ComplianceTest.t.sol) — `testPreviewDepositMustNotRevert` and its siblings, on a locally deployed vault, not on the pilot.      |

## Fees

| #   | Property                                                                                                                               | Status     | Evidence                                                                                                                                                                                                                                                             |
| --- | -------------------------------------------------------------------------------------------------------------------------------------- | ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| F1  | The created vault's DAO management fee, performance fee and recipient are the factory's package for the **caller**, not for the owner. | tested     | [`FusionFactoryEthereum.t.sol`](../test/deployed-factories/FusionFactoryEthereum.t.sol) compares the FeeManager against `getBusinessClientFeePackages(caller)`; `vault:plan` refuses to plan when the resolved package differs from the expected one.                |
| F2  | The vault pays fees into the fee manager's own fee accounts, at the rates that manager reports.                                        | tested     | The 29 state checks in [`vault-state.mjs`](../tools/lib/vault-state.mjs), run after every simulation and by `vault:verify --config`; the rules themselves are covered by [`test-vault-state.mjs`](../tools/test-vault-state.mjs).                                    |
| F3  | Fee percentages are two-decimal percent (100 = 1%), numerically equal to basis points.                                                 | tested     | Same checks: the DAO fees read from the fee manager equal the basis-point values in the input.                                                                                                                                                                       |
| F4  | Performance fee is charged on gains only, and management fee accrues with time.                                                        | postulated | Covered for locally deployed vaults in [`PlasmaVaultFee.t.sol`](../test/vaults/PlasmaVaultFee.t.sol) (e.g. `testShouldExitFromTwoMarketsAaveV3SupplyAndCompoundV3SupplyAndCalculatePerformanceFee`), but not on the pilot path and not with the pilot's fee package. |
| F5  | A fee package change between planning and execution invalidates the plan.                                                              | postulated | `vault:plan` records the package it planned against and `vault:simulate` re-checks the implementation, but no check re-reads the fee package immediately before execution. That belongs to the preflight step.                                                       |

## Withdrawals

| #   | Property                                                                                              | Status     | Evidence                                                                                                                                                                                                                                                                                     |
| --- | ----------------------------------------------------------------------------------------------------- | ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| W1  | A depositor cannot redeem before the vault's redemption delay has passed.                             | tested     | [`Erc4626StrategyInvariantsEthereum.t.sol`](../test/deployed-factories/Erc4626StrategyInvariantsEthereum.t.sol) — `testW1…`: redeeming one second before the delay ends reverts with `AccountIsLocked(unlockTime)`; at the delay the same redeem succeeds and returns the deposit (±1 USDC). |
| W2  | After the delay, redeeming every share returns the deposit, minus rounding.                           | tested     | [`Erc4626StrategyLifecycleEthereum.t.sol`](../test/deployed-factories/Erc4626StrategyLifecycleEthereum.t.sol): assets out ≈ 100 000 USDC (±1 USDC), depositor whole, zero shares left.                                                                                                       |
| W3  | The withdraw window and the withdraw manager's owner match the factory's configuration and the vault. | tested     | `withdraw.window` and `withdraw.plasmaVault` in the state checks, compared against the factory's own `getWithdrawWindowInSeconds()`.                                                                                                                                                         |
| W4  | The request-based path (`request` → `redeemFromRequest`) works for the pilot.                         | postulated | The pilot vault has no instant-withdrawal fuses and no request fee configured; the path was not exercised. See [`PlasmaVaultScheduledWithdraw.t.sol`](../test/vaults/PlasmaVaultScheduledWithdraw.t.sol) for the locally deployed case.                                                      |
| W5  | Withdrawals that need funds held in the market pull them back through instant-withdrawal fuses.       | postulated | Not configured for the pilot; the lifecycle test exits the market explicitly before redeeming.                                                                                                                                                                                               |

## Permissions and limits

| #   | Property                                                             | Status          | Evidence                                                                                                                                                                                                                                                                                                                                                   |
| --- | -------------------------------------------------------------------- | --------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| P1  | The requested owner receives `OWNER_ROLE` with no execution delay.   | tested          | Both deployed-usage tests, and the `access.owner` / `access.ownerDelay` state checks.                                                                                                                                                                                                                                                                      |
| P2  | Only `ALPHA_ROLE` can execute fuse actions.                          | tested (partly) | The lifecycle test executes as the alpha; the negative case for the pilot is not asserted. Locally deployed coverage exists in [`IporPlasmaVaultRolesTest.t.sol`](../test/roles/IporPlasmaVaultRolesTest.t.sol).                                                                                                                                           |
| P3  | Only `FUSE_MANAGER_ROLE` can register fuses and grant substrates.    | tested          | `vault:configure` refuses with `MISSING_ROLE` before sending, and the fork test in [`test-configure-strategy.mjs`](../tools/test-configure-strategy.mjs) proves an operator without the role is rejected.                                                                                                                                                  |
| P4  | A fuse action against a substrate that was never granted reverts.    | tested          | [`Erc4626StrategyInvariantsEthereum.t.sol`](../test/deployed-factories/Erc4626StrategyInvariantsEthereum.t.sol) — `testP4…`: the deployed supply fuse `0x12FD0EE1…` refuses Gauntlet USDC Prime, a USDC vault that was not granted, with `Erc4626SupplyFuseUnsupportedVault("enter", vault)`; no external shares appear and the idle balance is unchanged. |
| P5  | A market cannot exceed its configured share of the vault's assets.   | tested          | Observed directly: supplying 60% against a 50% limit reverted with `MarketLimitExceeded(100001, 59999999999, 49999999999)` while building the lifecycle test; the committed test supplies 40% and passes. The revert is not asserted in a committed test.                                                                                                  |
| P6  | The market limit is a WAD fraction of total assets (1e18 = 100%).    | tested          | Same observation: a basis-point value produced an effective limit of zero. The unit is now enforced by the strategy configuration schema.                                                                                                                                                                                                                  |
| P7  | A private vault only accepts deposits from `WHITELIST_ROLE` holders. | postulated      | The lifecycle test grants the role and deposits; it does not assert that an address without it is refused.                                                                                                                                                                                                                                                 |

## Rounding and tolerances

- The lifecycle test uses an absolute tolerance of **1 USDC on 100 000 USDC**
  (`1e6` of `1e11`), which covers ERC4626 rounding on the way into and out of
  the external vault plus the Plasma Vault's own share rounding. Balances that
  should be exact — the idle balance after a supply, the share balance after a
  full redeem — are asserted with `assertEq`.
- Fee values are integers in basis points; no tolerance is applied to them.
- The balance fuse normalizes to WAD (18 decimals) regardless of the underlying
  token's decimals; USDC's 6 decimals are converted, not truncated.

## Gaps worth closing

The postulated rows above are the honest list. The ones that most affect an
agent working from this repository:

1. **W1** — no test that an early redeem reverts on the pilot vault.
2. **P4** — no test that a non-granted substrate is refused by the _deployed_ fuse.
3. **P5** — the market-limit revert was observed but is not committed as a test.
4. **A6** — no demonstration that yield accrues, because the fork is pinned.

Each of those is a separate task, not a footnote in an existing one.

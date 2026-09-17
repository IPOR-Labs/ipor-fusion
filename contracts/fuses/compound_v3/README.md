# Compound V3 Integration

## Overview

Compound V3 integration enables IPOR Fusion to supply collateral to a Compound V3 (Comet) market, supply,
borrow and repay the market's base token, claim COMP rewards, and track the net value of the position for
the vault NAV.

**What Compound V3 does:** each Compound V3 market is a single `Comet` contract with exactly **one
borrowable base token** (e.g. USDC for cUSDCv3) and a list of collateral assets. Collateral earns no
interest and cannot be borrowed by others. Two Compound V3 facts drive the design of this integration:

- **Supply and borrow of the base token share one signed balance.** An account's base position is a single
  signed principal (`supplyBase` / `withdrawBase` in Comet): withdrawing more base than supplied turns the
  remainder into debt, and supplying base while in debt repays the debt first. An account is therefore
  either a base lender or a base borrower on a given Comet, never both.
- **There is no "enable as collateral" switch.** Every supplied collateral asset counts towards the
  borrowing limit automatically, so no collateral fuse exists.

Collateralisation and liquidation are enforced by Comet using **Comet's own price feeds**. NAV in Fusion is
computed with the vault's `PriceOracleMiddleware` (see *Balance Calculation*).

## Market Structure

One Fusion market ID corresponds to exactly one Comet. Every Compound V3 fuse is bound to its Comet and
market through the constructor `(uint256 marketId_, address cometAddress_)`, stored as immutables
(`MARKET_ID`, `COMET`, `COMPOUND_BASE_TOKEN = COMET.baseToken()`).

Borrowing (IL-8270) is implemented and verified for:

- **Market ID 2** (`IporFusionMarkets.COMPOUND_V3_USDC`) — cUSDCv3 on Ethereum
  (`0xc3d688B66703497DAA19211EEdff47f25384cdc3`), base token USDC; collateral cbBTC, WETH, wstETH, WBTC

## Key Components

| Contract | Purpose |
|---|---|
| `CompoundV3SupplyFuse` | supply / withdraw collateral and base token (`COMET.supply` / `COMET.withdraw`); `instantWithdraw` path |
| `CompoundV3BorrowFuse` | `enter` = borrow the base token, `exit` = repay the base token (capped at outstanding debt) |
| `CompoundV3ClaimFuse` (`contracts/rewards_fuses/compound/`) | claim COMP rewards |
| `CompoundV3BalanceFuse` | **legacy** NAV fuse priced with Comet feeds — kept unchanged for existing non-borrowing vaults |
| `CompoundV3WithPriceOracleMiddlewareBalanceFuse` | NAV: `Σ position × middleware price − borrowBalanceOf × middleware price(base)`, in USD (WAD) — **required for borrowing vaults** |
| `ext/IComet` | subset of the Comet interface |

All fuses are stateless (immutables only), run via `delegatecall` from `PlasmaVault.execute` and act for the
vault itself — tokens are always supplied from and withdrawn / borrowed to the vault address.
`CompoundV3SupplyFuse` and `CompoundV3BorrowFuse` expose `enterTransient` / `exitTransient` variants.
`CompoundV3BorrowFuse` does **not** implement `IFuseInstantWithdraw` — a borrow is never a withdrawal source.

## Substrate Configuration

Substrates are **asset addresses encoded as `bytes32`** (`PlasmaVaultConfigLib.isSubstrateAsAssetGranted`).
No Compound-specific substrate encoding exists; the Comet is fixed by the fuse immutables.

Required substrates of market ID 2 for a borrowing vault (Ethereum):

| Substrate | Address | Needed by |
|---|---|---|
| USDC (base) | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | borrow fuse gate (`enter` and `exit`); supply fuse for base supply; balance fuse (adds base supply, which is 0 while borrowing) |
| cbBTC | `0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf` | supply fuse (collateral in / out), balance fuse (valuation) |
| WETH | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` | same |
| wstETH | `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0` | same |
| WBTC | `0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599` | same |

Permission model:

- **Market**: borrowing requires `CompoundV3BorrowFuse` to be added to the vault (otherwise
  `PlasmaVault.UnsupportedFuse`); the fuse is bound to cUSDCv3 via immutables.
- **Asset**: the base token (USDC) must be granted as a substrate of market ID 2 — checked in both `enter` and
  `exit` (`CompoundV3BorrowFuseUnsupportedAsset(action, asset)`).
- **Collateral**: supplying / withdrawing a collateral asset is gated by `CompoundV3SupplyFuse` on that asset's grant.

Other collateral assets listed on cUSDCv3 are out of scope — simply do not grant them.

### Example Configuration (cUSDCv3, Ethereum)

```solidity
bytes32[] memory substrates = new bytes32[](5);
substrates[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);   // base token: borrow / repay gate
substrates[1] = PlasmaVaultConfigLib.addressToBytes32(CBBTC);
substrates[2] = PlasmaVaultConfigLib.addressToBytes32(WETH);
substrates[3] = PlasmaVaultConfigLib.addressToBytes32(WSTETH);
substrates[4] = PlasmaVaultConfigLib.addressToBytes32(WBTC);
PlasmaVaultGovernance(vault).grantMarketSubstrates(IporFusionMarkets.COMPOUND_V3_USDC, substrates);
```

Borrowed USDC sits idle in the vault until used, and collateral sits idle in the vault before it is supplied and
after it is withdrawn from the Comet. Account for these balances with the `ERC20_VAULT_BALANCE` market
(`Erc20BalanceFuse`) and the balance dependency `COMPOUND_V3_USDC → ERC20_VAULT_BALANCE`, so both markets are
refreshed together. Grant as `ERC20_VAULT_BALANCE` substrates every market ID 2 asset that is **not** the vault
underlying (`Erc20BalanceFuse` skips the underlying): in a USDC-underlying vault that means the collaterals, in a
collateral-underlying vault USDC plus the other collaterals.

## Operations

### Supply (`CompoundV3SupplyFuse`)

```solidity
struct CompoundV3SupplyFuseEnterData { address asset; uint256 amount; }
struct CompoundV3SupplyFuseExitData  { address asset; uint256 amount; }
```

- **Enter**: `COMET.supply(asset, amount)` — collateral for non-base assets, base supply for the base token.
- **Exit**: withdraws `min(amount, COMET.balanceOf(vault))` for the base token or
  `min(amount, collateralBalanceOf(vault, asset))` for collateral. Withdrawing collateral that would break
  collateralisation reverts `NotCollateralized()` in Comet.
- **Instant withdraw** params: `[0] amount` (in vault-underlying units, set by the vault), `[1] asset`; Comet
  failures are caught and reported with `CompoundV3SupplyFuseExitFailed`. See *Instant Withdrawal Configuration*.
- ABI: `enter((address,uint256))`, `exit((address,uint256))`. Transient inputs `0 asset, 1 amount`;
  outputs `[asset, market, amount]`.

### Borrow / Repay (`CompoundV3BorrowFuse`)

Compound V3 can only lend its base token, so the borrow fuse takes **no asset parameter** — the asset is
always `COMPOUND_BASE_TOKEN`:

```solidity
struct CompoundV3BorrowFuseEnterData { uint256 amount; } // base token to borrow
struct CompoundV3BorrowFuseExitData  { uint256 amount; } // base token to repay; >= debt => full repay
```

**Enter (borrow)**

- `amount == 0` returns `(COMPOUND_BASE_TOKEN, COMET, 0)` without reverting.
- Requires the base token substrate grant, then calls `COMET.withdraw(COMPOUND_BASE_TOKEN, amount)`; the
  borrowed tokens land in the vault.
- **Base supply is consumed first.** If the vault holds a positive base supply on this Comet, the withdrawal
  first uses that supply and only the remainder becomes debt (single signed base balance). The fuse does not
  guard against this.
- The fuse performs no health or size pre-checks; Comet reverts:
    - `NotCollateralized()` — borrow above the borrowing limit (`Σ collateral × Comet price × borrowCF`),
      including a borrow with no collateral;
    - `BorrowTooSmall()` — the resulting total debt would be below `baseBorrowMin` (100 USDC on cUSDCv3).
- Emits `CompoundV3BorrowFuseEnter(version, asset, market, amount)`.

**Exit (repay)**

- `amount == 0` returns with amount 0 without reverting; otherwise the base token substrate grant is required.
- No outstanding debt (`COMET.borrowBalanceOf(vault) == 0`) returns with amount 0 without reverting.
- **Repay is capped at the outstanding debt**: `finalAmount = min(amount, borrowBalanceOf(vault))` — a repay can
  never turn into a base supply position; any excess stays in the vault as idle USDC.
- **Full repay** (`amount >= debt`, including `type(uint256).max`): `COMET.supply(base, type(uint256).max)`.
  Comet resolves `max` to the account's accrued borrow balance in the same block, so exactly the debt is
  pulled and the principal ends at 0 — no interest dust is left behind.
- **Partial repay**: `COMET.supply(base, finalAmount)`. A partial repay **may leave debt below
  `baseBorrowMin`** — Comet checks the minimum only when borrowing, not when repaying.
- Allowance: `forceApprove(COMET, finalAmount)` before the supply and `forceApprove(COMET, 0)` right after, so
  no residual allowance to Comet remains.
- The fuse does not cap the repay at the vault's idle balance: if the vault holds less than `finalAmount`, the
  token transfer reverts.
- Emits `CompoundV3BorrowFuseExit(version, asset, market, repaidAmount)`.

**Errors**: `CompoundV3BorrowFuseInvalidMarketId()`, `CompoundV3BorrowFuseInvalidAddress()` (constructor,
validated before any external call), `CompoundV3BorrowFuseUnsupportedAsset(string action, address asset)`.

- ABI: `enter((uint256))`, `exit((uint256))`.
- Transient inputs `0 amount`; outputs `[asset, market, amount]`.

> **Repay via the borrow fuse, not the supply fuse.** `CompoundV3SupplyFuse.enter(USDC, x)` also repays
> debt (single signed balance), but anything above the debt silently becomes a base supply position. Only
> `CompoundV3BorrowFuse.exit` caps the repay at the debt.

### Typical flow

```solidity
FuseAction[] memory actions = new FuseAction[](2);
actions[0] = FuseAction(supplyFuse, abi.encodeWithSignature("enter((address,uint256))",
    CompoundV3SupplyFuseEnterData({asset: WSTETH, amount: 10e18})));
actions[1] = FuseAction(borrowFuse, abi.encodeWithSignature("enter((uint256))",
    CompoundV3BorrowFuseEnterData({amount: 10_000e6})));
PlasmaVault(vault).execute(actions);

// full repay (capped at the accrued debt), then withdraw the collateral
actions[0] = FuseAction(borrowFuse, abi.encodeWithSignature("exit((uint256))",
    CompoundV3BorrowFuseExitData({amount: type(uint256).max})));
actions[1] = FuseAction(supplyFuse, abi.encodeWithSignature("exit((address,uint256))",
    CompoundV3SupplyFuseExitData({asset: WSTETH, amount: type(uint256).max})));
PlasmaVault(vault).execute(actions);
```

## Balance Calculation

### `CompoundV3WithPriceOracleMiddlewareBalanceFuse` (required for borrowing vaults)

For every substrate of the market:

1. `amount = COMET.balanceOf(vault)` for the base token, otherwise `COMET.collateralBalanceOf(vault, asset)`
2. skip if `amount == 0` — substrates without a position never touch the oracle
3. price the asset via the vault's `PriceOracleMiddleware` (`getAssetPrice`)
4. `balance += amount × price`, normalized to WAD using the asset decimals plus the returned price decimals

Then, **outside the substrate loop**:

5. `debt = COMET.borrowBalanceOf(vault)` (interest-accrued view); if non-zero, subtract
   `debt × middleware price(base token)` — debt is netted regardless of whether the base token is granted
6. return `balance.toUint256()` — reverts (`SafeCastOverflowedIntToUint`) if debt value exceeds the position value

The result is in USD (WAD); `PlasmaVault` converts it to the vault underlying with the middleware price of the
underlying. The fuse never calls `COMET.getPrice` or `COMET.getAssetInfoByAddress`, and contains no explicit
zero-price branch: the production `PriceOracleMiddleware` implementations revert before returning a missing,
zero or negative price, and that revert bubbles up. Constructor errors:
`CompoundV3WithPriceOracleMiddlewareBalanceFuseInvalidMarketId()`,
`CompoundV3WithPriceOracleMiddlewareBalanceFuseInvalidAddress()`.

### Why not the legacy `CompoundV3BalanceFuse`

The legacy fuse computes `Σ (base supply | collateral) × Comet price − borrowBalanceOf × Comet price(base)`.
It does net the debt, but it is unsuitable for borrowing vaults:

1. **Price source inconsistency.** It prices with `COMET.getPrice(feed)`, while everything else in the vault
   (idle USDC, collateral held in the vault via `ERC20_VAULT_BALANCE`, the underlying) uses
   `PriceOracleMiddleware`. For WETH and wstETH Comet uses different Chainlink aggregators (SVR / CAPO) than
   the middleware, so the prices drift apart by up to roughly ±0.5% in both directions. Every move of
   collateral between the vault and Comet then produces a NAV jump (e.g. 0.4% of $15M collateral = $60k,
   amplified relative to equity in leveraged strategies), which can be charged as performance fee when the
   exchange rate ends above the high-water mark.
2. **`BadAsset` brick.** It calls `COMET.getAssetInfoByAddress(asset)` for every non-base substrate; an asset
   not listed on the Comet reverts `BadAsset()` and blocks every balance refresh of the market. The new fuse
   only calls `collateralBalanceOf`, which returns 0 for unlisted assets.
3. **Negative net value reverts** — kept in the new fuse as well (see *Risks*); flooring at 0 would hide debt.
4. **Config sensitivity** — revoking a collateral substrate with open debt removes the collateral but keeps the
   debt in both fuses (see *Risks*).

Existing vaults that do not borrow can keep `CompoundV3BalanceFuse`; the legacy fuse is not modified.

### Migrating an existing vault to the new balance fuse

A market has exactly one balance fuse.

- `addBalanceFuse(2, newFuse)` **overrides the current balance fuse directly**; it does not require an empty
  market and does not require removing the old fuse first.
- `removeBalanceFuse(2, oldFuse)` is optional and reverts `BalanceFuseNotReadyToRemove` while the old fuse
  reports more than dust (i.e. with an open position). After an override the old fuse is no longer mapped, so
  removing it reverts `BalanceFuseDoesNotExist`.
- **Prefer an empty-position migration.** Switching the price source on a live position can create a one-time
  NAV delta on the next balance refresh, with a potential performance-fee effect. Exit the position, replace the
  fuse, then re-enter. New borrowing vaults should configure the new fuse from inception.

## Instant Withdrawal Configuration

> **Warning.** `CompoundV3SupplyFuse.instantWithdraw` receives `params[0]` in **vault-underlying units** and
> performs no price or decimal conversion.

- Configure a `CompoundV3SupplyFuse` instant-withdraw entry **only when its asset equals the vault underlying**.
  Never configure a collateral leg of a different asset (e.g. WETH collateral in a USDC vault).
- A USDC entry is therefore valid only for a USDC-underlying vault, and it can only withdraw a **positive base
  supply**. While the account has base debt its base supply is 0, so the entry withdraws nothing and cannot
  source liquidity for redemptions.
- `CompoundV3BorrowFuse` is never an instant-withdraw source.
- Redemptions are served from idle underlying first; borrowed USDC held idle in a USDC-underlying vault can be
  redeemed without touching the Compound position.

## Price Oracle Setup

The vault's `PriceOracleMiddleware` must price every asset the vault holds a position in on the market (the
four collaterals and USDC for the debt). A missing source reverts `UnsupportedAsset`; zero or negative oracle
results also revert inside the middleware — in both cases every balance refresh of market ID 2 reverts.

Sources on the shared Ethereum middleware proxy `0xB7018C15279E0f5990613cc00A91b6032066f2f7`, at the time of
writing (Ethereum block 25,982,679):

| Asset | Middleware source |
|---|---|
| USDC | `0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6` (Chainlink USDC/USD — same feed as Comet's base feed) |
| WETH | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` (Chainlink ETH/USD) |
| wstETH | `0x4329e2178D41D058Cf2808c11436A9e83BC5D8b0` |
| WBTC | `0x106f9537Dd66423E6674e85CA187B43055B59fe9` |
| cbBTC | no explicit source → Chainlink Feed Registry fallback (`0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf`) |

Comet uses its own feeds for the borrowing limit and liquidation; they are not guaranteed to match the
middleware (e.g. Comet's cbBTC feed differs from the one the Feed Registry resolves).

## Risks

The fuses deliberately do **not** validate position health or the consequences of grant changes; the
following are documented risks, not enforced invariants.

- **Negative net balance.** `balanceOf` converts `int256 → uint256` with `toUint256()`. If debt value exceeds
  the valued position (price crash before a permissionless `absorb`, long-unpaid interest, or revoked collateral
  substrates), the balance update reverts and blocks every `execute` / withdrawal that refreshes this market —
  including a partial repay that leaves the net still negative — until the position is absorbed or repaid
  enough. Same behaviour as the Aave V3 balance fuses.
- **Oracle dependency.** NAV depends on middleware feeds for all four collaterals and USDC, while Comet
  liquidations follow Comet's own feeds (SVR / CAPO). Health on Compound may differ slightly from what the vault
  NAV implies.
- **Single signed base balance.** A vault that is a USDC lender on cUSDCv3 (market ID 2) cannot be a borrower at
  the same time; borrowing first withdraws its USDC supply.
- **Supply fuse repay path.** `CompoundV3SupplyFuse.enter(USDC)` also repays debt and turns any excess into a
  supply position — alphas should repay via `CompoundV3BorrowFuse.exit`.
- **Debt below `baseBorrowMin`.** A partial repay may leave debt below 100 USDC; further borrows must bring the
  total debt back to at least `baseBorrowMin`.
- **Instant withdrawal config.** Configure `CompoundV3SupplyFuse` for instant withdrawal only when its asset
  equals the vault underlying (see *Instant Withdrawal Configuration*); while the account has base debt a USDC
  entry no-ops.
- **Substrate revocation with open debt.** Revoking a collateral substrate drops that collateral from NAV while
  the debt stays → NAV understated or a negative-net revert. Withdraw collateral / repay before revoking.
- **USDC substrate revocation with open debt.** Revoking the USDC substrate while debt is open blocks repay
  through both `CompoundV3BorrowFuse.exit` and `CompoundV3SupplyFuse.enter(USDC)` until USDC is granted again;
  the debt keeps accruing and is still subtracted from NAV.
- **Balance fuse migration on a live position.** Replacing `CompoundV3BalanceFuse` with the middleware fuse while
  a position is open can cause a one-time NAV delta and performance-fee effect.
- **Liquidation.** Compound V3 `absorb` seizes **all** collateral of an under-collateralised account
  (liquidateCF 0.85–0.88 for the four assets). Monitoring is off-chain; the fuses provide no protection.
- **Supply caps.** Comet enforces per-asset supply caps; cbBTC has the tightest cap (900 cbBTC, about 359 used at
  the time of writing, Ethereum block 25,982,679).

## Mainnet Reference (Ethereum, at the time of writing — block 25,982,679)

cUSDCv3 `0xc3d688B66703497DAA19211EEdff47f25384cdc3`, base token USDC, `baseBorrowMin` = 100 USDC.

| Collateral | borrowCF | liquidateCF | supplyCap |
|---|---|---|---|
| WBTC | 0.80 | 0.85 | 10,000 |
| WETH | 0.825 | 0.88 | 500,000 |
| wstETH | 0.82 | 0.86 | 75,000 |
| cbBTC | 0.80 | 0.85 | 900 |

| Fuse | Address |
|---|---|
| `CompoundV3SupplyFuse` (market 2) | `0x00A220F09C1CF5f549C98Fa37C837aed54aBA26c` |
| `CompoundV3ClaimFuse` | `0x2B98080341D9469d8beAbf2db037dE8897c232cD` |
| `CompoundV3BalanceFuse` (market 2, legacy) | `0x7070d0A706Bf79A1e6d12706b9a429b9D8099C8b` |
| `CompoundV3BorrowFuse` (market 2) | not deployed yet |
| `CompoundV3WithPriceOracleMiddlewareBalanceFuse` (market 2) | not deployed yet |

## Tests

All tests for the borrow and middleware balance fuses are Ethereum mainnet fork tests (`ETHEREUM_PROVIDER_URL`,
block 25,982,679) against real contracts only — real `PlasmaVault`, Comet, tokens and `PriceOracleMiddleware`,
no mocks:

- `test/fuses/compound_v3/CompoundV3BorrowFuseTest.t.sol`
- `test/fuses/compound_v3/CompoundV3WithPriceOracleMiddlewareBalanceFuseTest.t.sol`
- `test/integrationTest/compoundV3Ethereum/CompoundV3BorrowEthereum.t.sol` — full lifecycle per collateral
  (cbBTC, WETH, wstETH, WBTC), balance fuse override, idle-USDC redemption

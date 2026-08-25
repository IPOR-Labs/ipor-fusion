# Aave V4 Integration

## Overview

Aave V4 integration enables IPOR Fusion to supply, borrow and manage collateral on the Aave V4 lending
protocol through its **Spoke** contracts, while tracking the net value of all positions for the vault NAV.

**What Aave V4 does:** Aave V4 (live on Ethereum since 2026-03-30) is built around a Hub & Spoke
architecture. Liquidity lives in Hubs (Core, Prime, Plus, Global Dollar); users interact with Spokes
(Main, Bluechip, Ethena Correlated, Forex, Gold, …), each with its own risk parameters, oracle and reserve
list. A Spoke reserve is identified by a sequential, **append-only `reserveId`** and points to one asset of
one Hub. The same underlying can therefore be listed **more than once on a single Spoke** — e.g. the
Bluechip Spoke lists USDC as reserve 4 (Prime hub) and reserve 7 (Core hub) with different rates and caps.

Two Aave V4 facts drive the design of this integration:

- **Supplying does not enable collateral.** Only reserves flagged via `setUsingAsCollateral` count towards
  the health factor; without it every `borrow` reverts with `HealthFactorBelowThreshold`. Hence the
  `AaveV4CollateralFuse`.
- **There is no E-Mode in Aave V4.** Risk segmentation is done by choosing the Spoke.

## Market Structure

The integration uses a single market for all Spokes:

- **Market ID 49** (`IporFusionMarkets.AAVE_V4`) — supply / withdraw / borrow / repay / collateral / balance

## Key Components

| Contract | Purpose |
|---|---|
| `AaveV4SupplyFuse` | `supply` / `withdraw` on a reserve; `instantWithdraw` path for user withdrawals |
| `AaveV4BorrowFuse` | `borrow` / `repay` on a reserve |
| `AaveV4CollateralFuse` | enable / disable a reserve as collateral of the vault |
| `AaveV4BalanceFuse` | NAV: `Σ (supplied − total debt) × price` over granted reserves, in USD (WAD) |
| `AaveV4SubstrateLib` | reserve substrate encoding + permission checks |
| `ext/IAaveV4Spoke` | subset of the real `ISpoke` (struct layouts identical) |

All fuses are stateless (`VERSION`, `MARKET_ID` immutables only), run via `delegatecall` from
`PlasmaVault.execute`, and expose `enterTransient` / `exitTransient` variants. The vault acts for itself on
the Spoke (`onBehalfOf == msg.sender`) — **no position manager is ever approved**.

## Substrate Configuration

One substrate = one Aave V4 reserve the vault may touch, plus capability flags (Euler-style):

```solidity
struct AaveV4Substrate {
    address spoke;        // Aave V4 Spoke
    uint32  reserveId;    // reserve index within the Spoke (append-only => stable)
    bool    isCollateral; // may be enabled as collateral   (AaveV4CollateralFuse.enter)
    bool    canBorrow;    // may be borrowed                (AaveV4BorrowFuse.enter)
}
```

`bytes32` layout:

```
bits 255..248  uint8   type flag       1 = Reserve (0 = undefined / invalid)
bits 247..88   address spoke
bits  87..56   uint32  reserveId
bits  55..48   uint8   flags           bit0 = isCollateral, bit1 = canBorrow
bits  47..0    reserved, zero
```

Encoding: `AaveV4SubstrateLib.encodeReserve(spoke, reserveId, isCollateral, canBorrow)`
(reverts if `reserveId > type(uint32).max`).

### Validation matrix

| Action | Requires |
|---|---|
| `AaveV4SupplyFuse.enter` (supply) | any grant for `(spoke, reserveId)` |
| `AaveV4SupplyFuse.exit` (withdraw) | any grant |
| `AaveV4SupplyFuse.instantWithdraw` | grant, no granted variant has `isCollateral`, **and** the reserve is not currently enabled as collateral on the Spoke (`getUserReserveStatus`) |
| `AaveV4BorrowFuse.enter` (borrow) | grant with `canBorrow` |
| `AaveV4BorrowFuse.exit` (repay) | any grant (repaying stays possible after `canBorrow` is revoked) |
| `AaveV4CollateralFuse.enter` (enable) | grant with `isCollateral` |
| `AaveV4CollateralFuse.exit` (disable) | any grant (the Spoke enforces the health factor) |

Lookups are O(1): `AaveV4SubstrateLib.getReserveGrant` probes the four flag variants of the pair and
returns their **union**, so the result does not depend on grant order. Grant exactly one variant per
reserve; should two variants be granted, the balance fuse de-duplicates by `(spoke, reserveId)`.
Only **canonical** words count: `isReserveSubstrate` rejects words with non-zero reserved bits (47..0) or
unknown flag bits, so a hand-encoded word that would never match a permission lookup is not valued either.

### Grant changes and open positions — atomist responsibilities

The fuses deliberately do **not** validate the consequences of granting or revoking substrates (no on-chain
check ties a grant change to existing positions). The atomist must respect the following when calling
`grantMarketSubstrates` (which always replaces the whole set):

| Situation | Effect | Rule |
|---|---|---|
| Reserve with **outstanding debt** loses its grant | the debt disappears from the balance fuse → **NAV overstated**, share price inflated | never revoke a reserve (or its Spoke) while the vault borrows it — repay first |
| Reserve with **supply** loses its grant | supply disappears from NAV (understated) and cannot be withdrawn until re-granted | withdraw first, or re-grant to recover |
| Reserve enabled as collateral is re-granted **without** `isCollateral` | collateral stays enabled on the Spoke; enabling again is refused, disabling still works; instant withdraw stays blocked by the on-chain status | disable collateral before downgrading the grant |
| Reserve with debt is re-granted **without** `canBorrow` | new borrows refused, repay still works, debt still counted | intended way to wind a position down |
| Reserve id granted before Aave lists it | ignored by the balance fuse; supply/borrow revert `ReserveNotListed` on the Spoke | harmless, becomes active once listed |

Only the last row is tolerated in code; the others are documented risks, not enforced invariants.

### Example Configuration (Bluechip Spoke, Ethereum)

```solidity
bytes32[] memory substrates = new bytes32[](3);
// WETH (reserve 0, Prime hub) - supply and use as collateral
substrates[0] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, 0, true, false);
// wstETH (reserve 3, Prime hub) - supply and use as collateral
substrates[1] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, 3, true, false);
// USDC via the Prime hub (reserve 4) - borrow only; reserve 7 (USDC via Core hub) stays out of reach
substrates[2] = AaveV4SubstrateLib.encodeReserve(BLUECHIP_SPOKE, 4, false, true);
PlasmaVaultGovernance(vault).grantMarketSubstrates(IporFusionMarkets.AAVE_V4, substrates);
```

## Operations

### Supply (`AaveV4SupplyFuse`)

```solidity
struct AaveV4SupplyFuseEnterData { address spoke; address asset; uint256 reserveId; uint256 amount; uint256 minShares; }
struct AaveV4SupplyFuseExitData  { address spoke; address asset; uint256 reserveId; uint256 amount; uint256 minAmount; }
```

- **Enter**: supplies `min(amount, vault balance)`; `minShares` slippage guard.
- **Exit**: withdraws `min(amount, supplied)`; `minAmount` slippage guard; `type(uint256).max` = full withdrawal.
- **Instant withdraw** params: `[0] amount` (set by the vault), `[1] asset`, `[2] spoke`, `[3] reserveId`, `[4] minAmount`.
  Reverts `AaveV4SupplyFuseInstantWithdrawNotAllowed` when the reserve may be collateral; Spoke failures
  are caught and reported with `AaveV4SupplyFuseExitFailed`.
- ABI: `enter((address,address,uint256,uint256,uint256))`, `exit((address,address,uint256,uint256,uint256))`.
- Transient inputs: `0 spoke, 1 asset, 2 reserveId, 3 amount, 4 minShares|minAmount`; outputs `[asset, amount]`.

### Borrow (`AaveV4BorrowFuse`)

```solidity
struct AaveV4BorrowFuseEnterData { address spoke; address asset; uint256 reserveId; uint256 amount; uint256 minShares; }
struct AaveV4BorrowFuseExitData  { address spoke; address asset; uint256 reserveId; uint256 amount; uint256 minSharesRepaid; }
```

- **Enter**: borrows `amount` (collateral must be enabled first); `minShares` guard.
- **Exit**: repays `min(amount, vault balance)`; the Spoke caps at the total debt (drawn + risk premium) and never
  pulls more than the approved amount — `amount = type(uint256).max` with enough balance repays everything.
- ABI and transient layout identical to the supply fuse (`minSharesRepaid` at index 4).

### Collateral (`AaveV4CollateralFuse`)

```solidity
struct AaveV4CollateralFuseEnterData { address spoke; uint256 reserveId; }
struct AaveV4CollateralFuseExitData  { address spoke; uint256 reserveId; }
```

- **Enter**: `setUsingAsCollateral(reserveId, true, vault)`; **Exit**: `…false…` (reverts
  `HealthFactorBelowThreshold` on the Spoke while debt depends on it).
- ABI: `enter((address,uint256))`, `exit((address,uint256))`. Transient inputs `0 spoke, 1 reserveId`;
  outputs `[spoke, reserveId]`.

### Typical flow

```solidity
FuseAction[] memory actions = new FuseAction[](3);
actions[0] = FuseAction(supplyFuse, abi.encodeWithSignature("enter((address,address,uint256,uint256,uint256))",
    AaveV4SupplyFuseEnterData({spoke: BLUECHIP_SPOKE, asset: WETH, reserveId: 0, amount: 10e18, minShares: 0})));
actions[1] = FuseAction(collateralFuse, abi.encodeWithSignature("enter((address,uint256))",
    AaveV4CollateralFuseEnterData({spoke: BLUECHIP_SPOKE, reserveId: 0})));
actions[2] = FuseAction(borrowFuse, abi.encodeWithSignature("enter((address,address,uint256,uint256,uint256))",
    AaveV4BorrowFuseEnterData({spoke: BLUECHIP_SPOKE, asset: USDC, reserveId: 4, amount: 10_000e6, minShares: 0})));
PlasmaVault(vault).execute(actions);
```

## Reserve/Asset Cross-check

Every supply/borrow action carries the expected `asset` and reverts with `…ReserveAssetMismatch(reserveId,
expected, actual)` when `spoke.getReserve(reserveId).underlying` differs. The grant itself is keyed by
`(spoke, reserveId)`; the cross-check is defense-in-depth against alpha typos.

## Balance Calculation

For every granted canonical Reserve substrate (de-duplicated by `(spoke, reserveId)`; reserve ids not listed
on the Spoke yet — `reserveId >= getReserveCount()` — are skipped so a pre-granted id cannot block balance updates):

1. `supplied = spoke.getUserSuppliedAssets(reserveId, vault)`
2. `debt = spoke.getUserTotalDebt(reserveId, vault)` — **always** queried, regardless of `canBorrow`,
   so a revoked borrow permission can never hide existing debt (includes the accrued risk premium)
3. skip if both are zero; otherwise price `spoke.getReserve(reserveId).underlying` via `PriceOracleMiddleware`
4. `net += (supplied − debt) × price`, normalized to WAD

Reverts `AaveV4BalanceFuseNegativeBalance` if total debt exceeds total supply value and
`Errors.UnsupportedQuoteCurrencyFromOracle` on a zero price.

## Security Considerations

- Grant changes are not validated against open positions — see *Grant changes and open positions* above;
  revoking a reserve that carries debt overstates the NAV until it is re-granted.

- Only granted Spokes are ever called; `withdraw`/`borrow` deliver tokens to the vault, `supply`/`repay`
  pull exactly the approved amount (`SafeERC20.forceApprove`).
- The vault never approves a position manager on any Spoke.
- Withdrawing or disabling collateral is health-factor checked by the Spoke; the revert bubbles up
  through `PlasmaVault.execute`.
- Instant withdraw is limited to non-collateral reserves — both by grant flag and by the live on-chain
  collateral status — so user withdrawals can never degrade a leveraged position. `instantWithdraw` also
  rejects malformed params (`AaveV4SupplyFuseInvalidParams`).
- Reserve `paused` / `frozen` flags and Hub caps are enforced by Aave; the fuses do not pre-check them.
- No storage variables in fuses; immutable `VERSION` / `MARKET_ID` only.

## Price Oracle Setup

`PriceOracleMiddleware` must provide a price for the underlying of every granted reserve (e.g. WETH/USD,
USDC/USD). Zero prices revert.

## Mainnet Reference (Ethereum, verified at block 25 800 000)

| Spoke | Address | Notes |
|---|---|---|
| Bluechip | `0x973a023A77420ba610f06b3858aD991Df6d85A08` | 0 WETH, 1 WBTC, 2 cbBTC, 3 wstETH (Prime hub, collateral); 4 USDC, 5 USDT, 6 GHO (Prime hub, borrow); 7 USDC, 8 frxUSD, 9 EURC, 10 USDT (Core hub, borrow) |
| Main | `0x94e7A5dCbE816e498b89aB752661904E2F56c485` | 0 WETH, 1 wstETH, 2 weETH, 3 WBTC, 4 cbBTC, 5 AAVE, 6 LINK, 7 USDC, 8 USDT, 9 EURC, 10 RLUSD, 11 USDG, 12 frxUSD, 13 GHO (Core hub) |

Hubs: Core `0xCca852Bc40e560adC3b1Cc58CA5b55638ce826c9`, Prime `0x943827DCA022D0F354a8a8c332dA1e5Eb9f9F931`,
Plus `0x06002e9c4412CB7814a791eA3666D905871E536A`. Full list: `bgd-labs/aave-address-book` → `AaveV4Ethereum.sol`.

## Tests

- Unit (mock Spoke): `test/fuses/aave_v4/AaveV4*FuseTest.t.sol`, `AaveV4SubstrateLibTest.t.sol`
- Ethereum mainnet fork (`ETHEREUM_PROVIDER_URL`, block 25 800 000): `AaveV4CreditMarketForkTest.t.sol`,
  `AaveV4BalanceFuseForkTest.t.sol`, `AaveV4InstantWithdrawForkTest.t.sol` (shared setup in `AaveV4ForkTestBase.sol`)

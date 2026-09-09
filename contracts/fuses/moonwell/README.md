# Moonwell Integration

## Overview

The Moonwell integration lets an IPOR Fusion Plasma Vault supply, borrow, enable collateral
and claim rewards on **Moonwell**, a Compound V2-style lending protocol on Base. The vault
holds mTokens (`MErc20`) directly and acts for itself on the Moonwell Comptroller.

**What Moonwell does:** every listed asset has an mToken market. Supplying mints mTokens
that accrue interest through the exchange rate; entering a market on the Comptroller makes
the supplied balance count as collateral; borrowing draws the underlying of another market
against that collateral. Emissions (WELL and other tokens) are distributed per market by the
Comptroller's `MultiRewardDistributor`.

## Market Structure

The integration uses a single market for all operations:

- **Market ID 21** (`IporFusionMarkets.MOONWELL`) — supply / withdraw / borrow / repay /
  enter and exit markets / balance / claim rewards

## Key Components

| Contract                                                       | Purpose                                                                                            |
| -------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `MoonwellSupplyFuse`                                           | `mint` / `redeemUnderlying` on the mToken of an asset; `instantWithdraw` path for user withdrawals |
| `MoonwellBorrowFuse`                                           | `borrow` / `repayBorrow` on the mToken of an asset                                                 |
| `MoonwellEnableMarketFuse`                                     | `enterMarkets` / `exitMarket` on the Comptroller (collateral on / off)                             |
| `MoonwellBalanceFuse`                                          | NAV: `Σ (balanceOfUnderlying − borrowBalanceStored) × price` over granted mTokens, in USD (WAD)    |
| `MoonwellHelperLib`                                            | resolves the mToken of an underlying among the granted substrates                                  |
| `rewards_fuses/moonwell/MoonwellClaimFuse`                     | claims emissions for given mTokens and forwards them to the `RewardsClaimManager`                  |
| `ext/MErc20`, `ext/MComptroller`, `ext/MultiRewardDistributor` | minimal interfaces of the Moonwell contracts                                                       |

All fuses are stateless (`VERSION`, `MARKET_ID` immutables; the enable-market and claim
fuses also hold the Comptroller address), run via `delegatecall` from `PlasmaVault.execute`
and, in this checkout, expose `enterTransient` / `exitTransient` variants.

## Substrate Configuration

Substrates are **mToken addresses** (`MErc20`), granted as plain addresses:

```solidity
bytes32[] memory substrates = new bytes32[](2);
substrates[0] = PlasmaVaultConfigLib.addressToBytes32(M_USDC); // Moonwell USDC market
substrates[1] = PlasmaVaultConfigLib.addressToBytes32(M_WETH); // Moonwell WETH market
PlasmaVaultGovernance(vault).grantMarketSubstrates(IporFusionMarkets.MOONWELL, substrates);
```

How each fuse uses the list:

| Fuse                       | Check                                                                                      |
| -------------------------- | ------------------------------------------------------------------------------------------ |
| `MoonwellSupplyFuse`       | `MoonwellHelperLib.getMToken`: the granted mToken whose `underlying()` equals `data.asset` |
| `MoonwellBorrowFuse`       | same resolution by underlying                                                              |
| `MoonwellEnableMarketFuse` | every `mTokens[i]` must be a granted address (`MoonwellEnableMarketFuseUnsupportedMToken`) |
| `MoonwellBalanceFuse`      | iterates the list                                                                          |
| `MoonwellClaimFuse`        | does **not** read the list; any mToken may be passed                                       |

An asset with no granted mToken reverts `MoonwellSupplyFuseUnsupportedAsset` (the error is
declared in `MoonwellHelperLib` and used by the supply and borrow fuses alike).

## Operations

### Supply (`MoonwellSupplyFuse`)

```solidity
struct MoonwellSupplyFuseEnterData {
    address asset;
    uint256 amount;
}
struct MoonwellSupplyFuseExitData {
    address asset;
    uint256 amount;
}
```

- **Enter**: `mint(min(amount, vault balance))`; a non-zero Compound error code reverts
  `MoonwellSupplyFuseMintFailed`. Amount in the asset's smallest unit; `0` is a no-op.
- **Exit**: `redeemUnderlying(min(amount, balanceOfUnderlying))`. A zero redeem result is
  reported by `MoonwellSupplyExitFailed`, not by revert. No slippage guard.
- **Instant withdraw** params: `[0] amount`, `[1] asset`; failures are caught and reported by event.
- ABI: `enter((address,uint256))` `0xd5ee7916`, `exit((address,uint256))` `0x92876ac8`.
- Transient inputs `0 asset, 1 amount`; outputs `[asset, mToken, amount]`.

### Borrow (`MoonwellBorrowFuse`)

```solidity
struct MoonwellBorrowFuseEnterData {
    address asset;
    uint256 amount;
}
struct MoonwellBorrowFuseExitData {
    address asset;
    uint256 amount;
}
```

- **Enter**: `borrow(amount)` on the resolved mToken; collateral must already be enabled
  through `MoonwellEnableMarketFuse`, otherwise the Comptroller returns an error and the fuse
  reverts `MoonwellBorrowFuseBorrowFailed`. The amount is not capped.
- **Exit**: approves the mToken, `repayBorrow(amount)`, revokes the approval; a non-zero
  error code reverts `MoonwellBorrowFuseRepayFailed`. The amount is not capped at the vault
  balance — pass at most what the vault holds.
- ABI identical to the supply fuse; transient layout identical.

### Collateral (`MoonwellEnableMarketFuse`)

```solidity
struct MoonwellEnableMarketFuseEnterData {
    address[] mTokens;
}
struct MoonwellEnableMarketFuseExitData {
    address[] mTokens;
}
```

- **Enter**: `Comptroller.enterMarkets(mTokens)`; any non-zero code is reported by
  `MoonwellMarketEnableFailed` for the whole batch. Empty list reverts.
- **Exit**: `Comptroller.exitMarket(mToken)` one by one; a market backing outstanding debt
  cannot be exited and only emits `MoonwellMarketDisableFailed`.
- ABI: `enter((address[]))` `0x5e047043`, `exit((address[]))` `0xf7edc378`.
- Transient inputs `0 length, 1..n mTokens`; outputs `[length, mTokens…]`.

### Rewards (`MoonwellClaimFuse`)

```solidity
struct MoonwellClaimFuseData {
    address[] mTokens;
}
```

`claim((address[]))` `0x3e32a78f` reads the emission tokens of each mToken from the
Comptroller's `rewardDistributor()`, calls `Comptroller.claimReward(vault, [mToken])` and
transfers every increase of the vault's balance in those tokens to the `RewardsClaimManager`.
It is registered on the `RewardsClaimManager` (`addRewardFuses`, `FUSE_MANAGER_ROLE`) and
executed through `RewardsClaimManager.claimRewards` by `CLAIM_REWARDS_ROLE` (600), not
through `PlasmaVault.execute`. Reverts when the distributor or the claim manager is unset.

## Balance Calculation

For every granted mToken:

1. `supplied = mToken.balanceOfUnderlying(vault)` (accrues interest — a state-changing call)
2. `borrowed = mToken.borrowBalanceStored(vault)` (stored, not accrued)
3. price `mToken.underlying()` through the vault's `PriceOracleMiddleware`; a zero price
   reverts `MoonwellBalanceFuseInvalidPrice`
4. `net += (supplied − borrowed) × price`, normalized to WAD

A negative net balance is returned as **0**, not as a revert. A second entry point
`balanceOf(bytes32[] substrates, address plasmaVault)` values an arbitrary substrate list
for an arbitrary vault.

## Price Oracle Setup

A price source is required for the **underlying** of every granted mToken (USDC, WETH,
cbETH, …); the mTokens themselves are never priced. Configure it on the vault's
`PriceOracleMiddlewareManager` or `PriceOracleMiddleware`
(`PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE`).

## Roles

| Action                                  | Role                                                              |
| --------------------------------------- | ----------------------------------------------------------------- |
| execute supply / borrow / enable market | `ALPHA_ROLE` (200) via `PlasmaVault.execute`                      |
| register fuses and the balance fuse     | `FUSE_MANAGER_ROLE` (300)                                         |
| grant mToken substrates                 | `FUSE_MANAGER_ROLE` (300)                                         |
| set the market limit                    | `ATOMIST_ROLE` (100)                                              |
| add price sources                       | `PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE` (1200)                     |
| claim rewards                           | `CLAIM_REWARDS_ROLE` (600) via `RewardsClaimManager.claimRewards` |

## Tests

Fork tests on Base (block 22136992, `BASE_PROVIDER_URL`):

- `test/fuses/moonwell/MoonwellSupplyFuseBaseTest.sol` — supply / withdraw / instant withdraw
- `test/fuses/moonwell/MoonwellBorowFlowBaseTest.t.sol` — enable market, borrow, repay, balance
- `test/fuses/moonwell/MoonwellClaimFuseBaseTest.sol` — reward claiming through the claim manager
- `test/context/ContextManagerRewardsClaimManagerTest.t.sol` and the `WithSignature` variant
  use the supply fuse as the reward-bearing position

`test/fuses/moonwell/FluidProofClaimFuseTest.t.sol` lives in this directory but tests the
Fluid proof claim fuse on Ethereum; it is not a Moonwell test.

## Deployed Fuses

The Base deployments registered in `IPOR-Labs/ipor-abi` (`SupplyFuseMoonwell`,
`BorrowFuseMoonwell`, `EnableMarketFuseMoonwell`, `BalanceFuseMoonwell`,
`ClaimRewardsFuseMoonwell`) answer `MARKET_ID() == 21` and carry the `enter`/`exit`/`claim`
selectors of this checkout, but the three action fuses do **not** contain
`enterTransient()`/`exitTransient()` and the balance fuse reverts on `VERSION()`: they are
older versions of these sources. Details and block numbers are recorded in
[`catalog/fuses.json`](../../../catalog/fuses.json), entry `base-moonwell-market-21`.

## Security Notes

- `MoonwellBorrowFuse.exit` and `MoonwellBorrowFuse.enter` do not cap the amount; the
  Moonwell contracts revert or return an error code on insufficient balance or liquidity.
- Withdrawals and collateral exits are health-checked by the Comptroller; a failed
  `redeemUnderlying` on the instant-withdraw path is reported by event and does not revert
  the user's withdrawal.
- `balanceOfUnderlying` accrues interest, so `balanceOf()` of the balance fuse is not a
  view; `borrowBalanceStored` does not accrue, so the debt side can lag until the next accrual.
- The claim fuse forwards rewards to the `RewardsClaimManager`; their valuation is that
  manager's business, not the balance fuse's.

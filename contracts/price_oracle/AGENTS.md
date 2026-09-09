# Price oracle contributor instructions

These instructions supplement the repository root `AGENTS.md` for
`contracts/price_oracle/` and its subdirectories.

## Start here

- Read [`../../docs/architecture.md`](../../docs/architecture.md) for where the
  oracle sits in the balance-refresh path: every `execute` ends by pricing the
  vault's underlying asset and every balance fuse prices its own positions.
- Read [`../../docs/roles-and-permissions.md`](../../docs/roles-and-permissions.md)
  before changing who may register or replace a price source.
- Read [`../../docs/deployments.md`](../../docs/deployments.md) for the one
  verified price-feed factory and the caveats of the feed it creates.

There is no written oracle-manipulation policy in `docs/`. The rules below are
what the code enforces today; a new guarantee has to be added to the code and to
[`../../docs/invariants.md`](../../docs/invariants.md) together.

## Three layers, two of them per vault

1. **Global middleware** — [`PriceOracleMiddleware.sol`](PriceOracleMiddleware.sol)
   (owner-gated) and [`PriceOracleMiddlewareWithRoles.sol`](PriceOracleMiddlewareWithRoles.sol)
   (role-gated, can also create and register Pendle PT feeds). Both are UUPS
   proxies and store the asset-to-source map in
   [`PriceOracleMiddlewareStorageLib.sol`](PriceOracleMiddlewareStorageLib.sol);
   its ERC-7201 slot is fixed and must not change.
2. **Per-vault manager** —
   [`../managers/price/PriceOracleMiddlewareManager.sol`](../managers/price/PriceOracleMiddlewareManager.sol),
   cloned by the factory for every vault. This is the address the vault stores
   as its `priceOracleMiddleware`. It checks its own source map first and falls
   back to the global middleware, and it is the only layer with a removal
   function and with optional price-change validation.
3. **Feeds** — everything under [`price_feed/`](price_feed/) implements
   [`price_feed/IPriceFeed.sol`](price_feed/IPriceFeed.sol) directly: an
   AggregatorV3-shaped `decimals()` and `latestRoundData()`. There is no base
   contract to inherit from.

The vault reads prices through `PlasmaVaultLib.getPriceOracleMiddleware()` in
`contracts/vaults/lib/PlasmaVaultMarketsLib.sol`. A change in this directory
therefore reaches every vault that uses the global middleware, and a change in a
manager reaches one vault. Say which one your task touches.

## Resolution and units

`getAssetPrice(asset)` returns the USD price **in WAD** (`decimals` is always 18) regardless of what the feed returns. The middleware resolves, in order:

1. `asset == address(0)` reverts `UnsupportedAsset`;
2. a configured source: its `decimals()` and `latestRoundData()`;
3. otherwise the immutable Chainlink feed registry with the USD quote, if one
   was set in the constructor; a failed registry call reverts `UnsupportedAsset`.

The raw answer is scaled with `IporMath.convertToWad(price, feedDecimals)`, then
rejected if zero. Consequences:

- Feeds in this tree use both 8 and 18 decimals. Never hard-code either side;
  always read `decimals()` from the feed you consume.
- Scaling a high-decimal feed down uses integer division and can floor a tiny
  price to zero; `test/price_oracle/PriceOracleMiddlewareWithRolesIntegerDivisionTest.t.sol`
  exists for exactly this case.
- Neither middleware checks `updatedAt`, `roundId` or `answeredInRound`. **There
  is no staleness or heartbeat check** unless the feed itself performs one, as
  [`price_feed/ChainlinkGuardedPriceFeed.sol`](price_feed/ChainlinkGuardedPriceFeed.sol)
  does with a bounded `MAX_STALE_PERIOD`. Most computed feeds return zero
  timestamps and a zero round ID.
- The owner-gated middleware relies on `SafeCast` to reject a negative answer;
  the role-gated one checks the sign explicitly before converting. Put a new
  check on the explicit side.
- A source can be replaced on the global middleware but never cleared back to
  `address(0)`, and writing a custom source silently disables the Chainlink
  registry fallback for that asset. Only the per-vault manager can remove one.

## Feeds that call back into the middleware

Several feeds price a derivative in terms of another asset and ask the
middleware for that asset's price. Two conventions coexist:

- **`msg.sender` as middleware** —
  [`price_feed/ERC4626PriceFeed.sol`](price_feed/ERC4626PriceFeed.sol) and the
  Napier feeds. Such a feed answers correctly only when read by a middleware or
  a manager. Reading it directly, including from a test, is a different
  question; prank the middleware as the caller, as
  `test/deployed-factories/Erc4626PriceFeedFactoryEthereum.t.sol` does.
- **Middleware fixed in the constructor** —
  [`price_feed/PtPriceFeed.sol`](price_feed/PtPriceFeed.sol),
  [`price_feed/CurveStableSwapNGPriceFeed.sol`](price_feed/CurveStableSwapNGPriceFeed.sol)
  and others. Such a feed keeps pointing at the global middleware even when the
  vault that uses it has its own manager with an override for the same asset.

Nothing detects a cycle in the asset-to-feed graph; it surfaces as out of gas.
When registering a feed that depends on another asset, confirm that asset already
resolves and does not resolve back through the feed being added.

## Valuation source

Prefer protocol accounting over spot state, the same rule the fuse instructions
apply to balance fuses:

- `convertToAssets` on an ERC-4626 vault, an accrued index, or a TWAP (the Pendle
  feed enforces a minimum TWAP window) is acceptable input.
- `CurveStableSwapNGPriceFeed` prices an LP token from live `balances()` and
  `totalSupply()`. A swap in the same transaction moves that value. Treat any
  new feed built on reserves as a finding unless the task explicitly accepts the
  risk and the handoff says so.
- A feed on a share token inherits the donation and inflation exposure of the
  underlying vault. State it when adding one.

## Change checklist

1. Name the consumer: which vaults resolve through the global middleware, and
   whether the target vault has a manager override for the same asset.
2. Keep `getAssetPrice` returning WAD with `decimals == 18`; keep `IPriceFeed`
   unchanged. Both are consumed by every balance fuse and by external tooling.
3. Validate in the constructor what can be validated there: nonzero addresses,
   feed decimals, and that every dependency asset resolves.
4. Reject non-positive answers before scaling. Document what the feed does with
   timestamps; do not invent a fresh `block.timestamp` where the source has none.
5. State the rounding direction of every division and the unit at every boundary
   (feed decimals, asset decimals, WAD).
6. Registering a feed is a separate privileged call. A feed factory under
   `contracts/factory/price_feed/` only deploys; `setAssetsPricesSources` on the
   middleware, or `setAssetsPriceSources` on a manager, is what makes the vault
   use it. The role-gated middleware's PT path is the one place that does both.
7. Do not change the storage slot of `PriceOracleMiddlewareStorageLib`, the UUPS
   authorization, event shapes or the compiler settings. Event parameters stay
   non-`indexed`.

## Tests and evidence

Every suite under [`../../test/price_oracle/`](../../test/price_oracle/),
[`../../test/price_oracle/price_feed/`](../../test/price_oracle/price_feed/) and
[`../../test/factory/price_feed/`](../../test/factory/price_feed/) is a fork test:
`setUp()` calls `vm.createSelectFork` with `ETHEREUM_PROVIDER_URL` or
`ARBITRUM_PROVIDER_URL` at a pinned block. There is no local oracle suite;
`npm run test:unit` does not reach this directory. A missing provider or missing
archive state is an infrastructure limitation, not an oracle result.

- Middleware: `test/price_oracle/PriceOracleMiddlewareTest.t.sol` and the
  `WithRoles` siblings; `PriceOracleMiddlewareMock.sol` is a helper for other
  suites, not a test of this directory.
- A feed: the file of the same name under `test/price_oracle/price_feed/`; a feed
  factory: `test/factory/price_feed/` or the `…FactoryTest` files that live next
  to the feed tests.
- Unchanged deployment: `test/deployed-factories/Erc4626PriceFeedFactoryEthereum.t.sol`
  is the only classified suite here (`deployed-price-feed-factory-ethereum-erc4626`
  in `config/test-suites.json`); the rest is deliberately unclassified, which is
  not evidence that a suite is local.

A price change propagates into every balance-fuse valuation, so after the direct
suite run the fuse or vault suites that price the affected asset. The unit of a
balance-fuse result (USD, 18 decimals) is a postulated invariant, not an asserted
one; a test that fixes it is welcome as its own change.

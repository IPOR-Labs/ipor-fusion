# PR #521 — sync: changes from private (2026-04-17)

- **Repo**: IPOR-Labs/ipor-fusion
- **PR**: https://github.com/IPOR-Labs/ipor-fusion/pull/521
- **Author**: Piotr Rzonsowski (pete-ipor)
- **Merged**: 2026-04-17
- **Source**: sync from `IPOR-Labs/private-ipor-fusion@main`

## Summary

Adds a DIA Data price feed wrapper: a `DIAPriceFeed` adapter conforming to the project's `IPriceFeed` interface, a factory for deploying instances, and an external interface for the DIA Oracle V2. Ships with unit tests for both the price feed and the factory.

## New components

- `contracts/price_oracle/price_feed/DIAPriceFeed.sol` (+123) — price feed adapter wrapping a DIA Oracle V2 data source.
- `contracts/factory/price_feed/DIAPriceFeedFactory.sol` (+66) — factory for deploying `DIAPriceFeed` instances.
- `contracts/price_oracle/ext/IDIAOracleV2.sol` (+16) — external interface for the DIA Oracle V2.

## Tests

- `test/price_oracle/price_feed/DIAPriceFeedTest.t.sol` (+228) — unit tests for the price feed adapter.
- `test/factory/price_feed/DIAPriceFeedFactoryTest.t.sol` (+138) — unit tests for the factory.

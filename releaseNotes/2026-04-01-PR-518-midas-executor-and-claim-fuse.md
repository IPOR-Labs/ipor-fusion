# PR #518 — sync: changes from private (2026-04-01)

- **Repo**: IPOR-Labs/ipor-fusion
- **PR**: https://github.com/IPOR-Labs/ipor-fusion/pull/518
- **Author**: Mario (mario-ipor)
- **Merged**: 2026-04-01
- **Source**: sync from `IPOR-Labs/private-ipor-fusion@main`

## Summary

Expands the Midas integration: introduces `MidasExecutor` (an execution contract for Midas flows), a new `MidasClaimFromExecutorFuse`, and extends `MidasBalanceFuse`. Ships an extensive unit test suite for the Midas fuses with accompanying mocks and harnesses.

## New components

- `contracts/fuses/midas/MidasExecutor.sol` — new executor contract for Midas operations.
- `contracts/fuses/midas/MidasClaimFromExecutorFuse.sol` — new fuse that handles claims from the executor.
- `contracts/fuses/midas/lib/MidasExecutorStorageLib.sol` — storage library for the executor.
- `contracts/fuses/midas/lib/MidasConstants.sol` — new Midas constants.

## Changes to existing contracts

- `contracts/fuses/midas/MidasBalanceFuse.sol` — significant rework (+99/-27).
- `contracts/fuses/midas/MidasRequestSupplyFuse.sol` — refactor (+18/-18).
- `contracts/fuses/midas/README.md` — documentation update.
- `contracts/price_oracle/price_feed/IPriceFeed.sol` — minor interface tweak (+3/-2).
- `contracts/vaults/PlasmaVault.sol` — minor change (+2/-2).

## Tests

Added a complete unit test suite under `test/unitTest/fuses/midas/`:

- `MidasExecutorFlowTest.t.sol` (+840) — end-to-end executor flow test.
- `MidasBalanceFuseTest.t.sol` (+1320)
- `MidasClaimFromExecutorFuseTest.t.sol` (+523)
- `MidasExecutorTest.t.sol` (+563)
- `MidasRequestSupplyFuseTest.t.sol` (+1530)
- `MidasSupplyFuseTest.t.sol` (+1163)
- Library tests: `MidasExecutorStorageLibTest`, `MidasPendingRequestsStorageLibTest`, `MidasSubstrateLibTest`.
- Full set of mocks and harnesses (ERC20, DepositVault, RedemptionVault, PriceOracle, DataFeed).
- `test/vaults/PlasmaVaultDepositFee.t.sol` (+84) — new test cases.

## Other

- `.env.example` — removed 5 lines (config cleanup).
- `test/fuses/PlasmaVaultMock.sol` — small addition (+13).

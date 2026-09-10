# Merkl Reward Claim Fuses

## Overview

The Merkl integration lets an IPOR Fusion Plasma Vault claim rewards that
[Merkl](https://merkl.xyz) distributes through its `Distributor` contract (Merkle-proof
claims). Two reward fuses live in `contracts/rewards_fuses/merkl/`:

- **`MerklClaimFuse`** — claims plain reward tokens and forwards the claimed amount to the
  `RewardsClaimManager`, optionally leaving named tokens on the vault.
- **`MerklClaimWrapperFuse`** — claims self-unwrapping reward wrappers: the wrapper
  unwraps on transfer into one or more "received" tokens, so the balance delta is measured on
  the received tokens the caller names, and every received token must be a granted substrate
  of the `MERKL` market.

Both are reward fuses: they are registered in the `RewardsClaimManager` (not in
`PlasmaVault.addFuses`) and executed through `RewardsClaimManager.claimRewards`, which calls
`PlasmaVault.claimRewards` and delegatecalls the fuse in the vault's storage context.

## Market Structure

- **Market ID `type(uint256).max - 3`** (`MERKL`) — used only by `MerklClaimWrapperFuse`
  (constructor argument) to gate which received tokens may be forwarded. `MerklClaimFuse`
  declares no `MARKET_ID` and reads no substrates.

Neither fuse holds a position, so no balance fuse is registered for this market.

## Architecture

### Key Components

- **`MerklClaimFuse`** (`constructor(address distributor_)`): `claim(address[] tokens_,
uint256[] amounts_, bytes32[][] proofs_, address[] doNotTransferToRewardManager_)`,
  selector `0x69ffbb47`.
- **`MerklClaimWrapperFuse`** (`constructor(uint256 marketId_, address distributor_)`):
  `claim(address[] tokens_, uint256[] amounts_, bytes32[][] proofs_, address[] receivedTokens_)`,
  selector `0x69ffbb47` (same signature, different meaning of the last parameter).
- **`ext/IDistributor`** — the Merkl Distributor interface (`claim(users, tokens, amounts, proofs)`).

### MerklClaimFuse.claim

| Parameter                       | Type          | Meaning                                                                                                                         |
| ------------------------------- | ------------- | ------------------------------------------------------------------------------------------------------------------------------- |
| `tokens_`                       | `address[]`   | Reward tokens to claim; the user of every claim is the Plasma Vault itself.                                                     |
| `amounts_`                      | `uint256[]`   | Cumulative claimable amount per token as published in the Merkl root, in the token's smallest unit.                             |
| `proofs_`                       | `bytes32[][]` | Merkle proof per token.                                                                                                         |
| `doNotTransferToRewardManager_` | `address[]`   | Tokens whose claimed delta stays on the vault (for rewards that are vault assets); every other delta goes to the claim manager. |

Flow: snapshot the vault's balance of each token, call `Distributor.claim`, then transfer the
positive delta of each token to the `RewardsClaimManager` unless the token is in the skip
list. Emits `MerklClaimFuseRewardsClaimed` per token with a positive delta.

### MerklClaimWrapperFuse.claim

| Parameter         | Type          | Meaning                                                                                                                                          |
| ----------------- | ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `tokens_`         | `address[]`   | Wrapper tokens to claim, passed to `Distributor.claim`.                                                                                          |
| `amounts_`        | `uint256[]`   | Cumulative claimable amount per wrapper, smallest unit.                                                                                          |
| `proofs_`         | `bytes32[][]` | Merkle proof per wrapper; `tokens_`, `amounts_` and `proofs_` must have the same length.                                                         |
| `receivedTokens_` | `address[]`   | Final tokens that land on the vault after unwrapping. Each must be granted as a substrate-as-asset of `MERKL`; each positive delta is forwarded. |

The received-token gate is checked before the claim, so an unsupported token reverts
deterministically (`MerklClaimWrapperFuseUnsupportedReceivedToken`). A balance decrease
between snapshot and read (rebasing aTokens) counts as a zero delta instead of reverting.
Unwrapped tokens are always forwarded, so they never linger on the vault and inflate the
share price when the token is also a market substrate.

## Balance Calculation

None. Claimed tokens are transferred to the `RewardsClaimManager`, which vests them into the
vault; tokens kept on the vault through `doNotTransferToRewardManager_` are valued by the
market that already holds that asset (typically `ERC20_VAULT_BALANCE`).

## Substrate Configuration

Only `MerklClaimWrapperFuse` reads substrates: the reward token addresses it may forward,
granted as plain addresses with `PlasmaVaultGovernance.grantMarketSubstrates(MERKL, ...)`
and checked with `PlasmaVaultConfigLib.isSubstrateAsAssetGranted`. Remember that
`grantMarketSubstrates` replaces the whole list.

## Price Oracle Setup

Not required by the fuses. Price sources matter only for the assets that end up valued in
other markets.

## Roles

- `CLAIM_REWARDS_ROLE` (600) calls `RewardsClaimManager.claimRewards`.
- `FUSE_MANAGER_ROLE` (300) registers the fuses with `RewardsClaimManager.addRewardFuses`
  and grants the `MERKL` substrates.
- The manager itself holds `TECH_REWARDS_CLAIM_MANAGER_ROLE` (601) to call
  `PlasmaVault.claimRewards`.

## Tests

- `test/fuses/merkl/MerklClaimFuseTest.t.sol` — Ethereum fork, block 23642516.
- `test/fuses/merkl/MerklClaimWrapperFuseTest.t.sol` — Base fork, block 46766277.

## Deployments

Names in the `IPOR-Labs/ipor-abi` registry (commit `a0089cf`): `MerklClaimFuse` on Ethereum,
Arbitrum, Base, Avalanche, Flare, Ink, Katana, Monad and Plasma; `MerklClaimWrapperFuse` on
Base, Flare and Monad; `MerklDistributor` `0x3Ef3D8bA38EBe18DB133cEc108f4D14CE00Dd9Ae` on
every one of them. The catalog entry `base-merkl-rewards-market-merkl` in
`catalog/fuses.json` records the Base deployments as observed at block 51079414.

## Security Notes

- `MerklClaimFuse` trusts the caller's token list: any token the distributor pays out is
  forwarded to the claim manager, and the skip list lets rewards stay on the vault. It has no
  substrate gate, so `CLAIM_REWARDS_ROLE` decides what is claimed and where it goes.
- `MerklClaimWrapperFuse` gates the received tokens through the `MERKL` substrates and always
  forwards them; do not grant a vault asset there unless the reward is meant to vest.
- Both fuses run under delegatecall in the vault's storage; they must not hold storage.

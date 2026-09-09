# Syrup Reward Claim Fuse

## Overview

`SyrupClaimFuse` (`contracts/rewards_fuses/syrup/`) lets an IPOR Fusion Plasma Vault claim a
token allocation from a Syrup (Maple) reward distributor — a Merkle-tree distributor where
each allocation has an id, an amount and a deadline and can be claimed once — and forwards
the claimed tokens to the `RewardsClaimManager`.

It is a reward fuse: registered with `RewardsClaimManager.addRewardFuses`, executed through
`RewardsClaimManager.claimRewards` → `PlasmaVault.claimRewards` (delegatecall in the vault's
storage context).

## Market Structure

The fuse declares no `MARKET_ID` and reads no substrates; it belongs to no market and needs
no balance fuse. The reward distributor is bound at construction
(`constructor(address rewardDistributor_)`, exposed as `REWARD_DISTRIBUTOR`), and the reward
token is read from it (`ISyrup.asset()`).

## Architecture

### SyrupClaimFuse.claim

`claim(uint256 id_, uint256 claimAmount_, bytes32[] proof_)`, selector `0xae0b51df`.

| Parameter      | Type        | Meaning                                                                                                |
| -------------- | ----------- | ------------------------------------------------------------------------------------------------------ |
| `id_`          | `uint256`   | Identifier of the allocation in the distributor's Merkle tree; claimable once, before its deadline.    |
| `claimAmount_` | `uint256`   | Amount to claim, in the smallest unit of `asset()`; zero reverts with `SyrupClaimFuseClaimAmountZero`. |
| `proof_`       | `bytes32[]` | Merkle proof that `(id, account = Plasma Vault, claimAmount)` is in the tree.                          |

Flow: read `asset()` from the distributor, snapshot the vault's balance, call
`ISyrup.claim(id_, plasmaVault, claimAmount_, proof_)`, transfer the positive delta to the
`RewardsClaimManager` and emit `SyrupClaimFuseRewardsClaimed`. A zero `RewardsClaimManager`
address reverts (`SyrupClaimFuseRewardsClaimManagerZeroAddress`).

## Balance Calculation

None. Claimed tokens are vested by the `RewardsClaimManager`.

## Substrate Configuration

None. The only configurable value is the distributor address given at deployment.

## Price Oracle Setup

Not required by the fuse.

## Roles

- `CLAIM_REWARDS_ROLE` (600) calls `RewardsClaimManager.claimRewards`.
- `FUSE_MANAGER_ROLE` (300) registers the fuse with `RewardsClaimManager.addRewardFuses`.

## Tests

- `test/fuses/syrup/SyrupClaimFuseTest.t.sol` — Ethereum fork, block 23696709 (2 tests).

## Deployments

`IPOR-Labs/ipor-abi` (commit `a0089cf`), Ethereum: `SyrupClaimFuse`
`0x5b1a6B2E6Af64E74275015A65687de0ca941f537`, `SyrupRewardDistributor`
`0x509712F368255E92410893Ba2E488f40f7E986EA` (the fuse's `REWARD_DISTRIBUTOR()` at block
25939091). Recorded in `catalog/fuses.json` as `ethereum-syrup-rewards-claim`.

## Security Notes

- The proof and amount are supplied by `CLAIM_REWARDS_ROLE`; the distributor validates them.
- The fuse runs under delegatecall and must not hold storage.

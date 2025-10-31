# RewardEulerTokenClaimFuse

## Overview

`RewardEulerTokenClaimFuse` is a fuse contract that enables claiming and converting locked Euler reward tokens (rEUL) into EUL tokens within the IPOR Fusion vault system. This fuse integrates with Euler's reward system to handle the vesting and conversion of rEUL tokens.

## What is rEUL?

Reward EUL (rEUL) is a locked form of EUL designed to incentivize early adopters of Euler v2. Users earn rEUL rewards by participating in supported Euler markets through both supply and borrow activities.

### Vesting Mechanism

rEUL tokens convert 1:1 into EUL over six months, following a non-linear unlock schedule:

-   **20% unlocks immediately**: Users can redeem a portion of their rEUL right away
-   **80% unlocks linearly over six months**: The remaining portion vests gradually
-   **Forfeiture**: Users can redeem unlocked EUL anytime, but locked EUL is forfeited and burned if not fully vested

### Important Characteristics

-   **Non-fungible**: Despite appearing as ERC-20 tokens, rEUL tokens are non-fungible. Each claim starts a separate vesting period, making each token position unique
-   **Transfer restrictions**: Most rEUL tokens are locked and cannot be transferred to general-purpose wallet addresses, except to whitelisted smart contracts for third-party Euler integrations

For more details, see the [official Euler documentation](https://docs.euler.finance/EUL/reward-eul).

## How It Works

### Claim Process

The fuse performs the following steps when `claim()` is called:

1. Retrieves the `RewardsClaimManager` address from the Plasma Vault
2. Calls `IREUL.withdrawToByLockTimestamps()` to withdraw rEUL tokens based on normalized lock timestamps
3. The rEUL contract automatically converts the vested portion to EUL tokens
4. EUL tokens are sent directly to the `RewardsClaimManager` address
5. Validates that the balance increased (or stayed the same) after the operation
6. Emits an event with the claimed amount

### ClaimData Structure

```solidity
struct ClaimData {
    uint256[] lockTimestamps; // Array of normalized lock timestamps to withdraw
    bool allowRemainderLoss; // Whether to allow remainder loss due to lock schedule
}
```

**Parameters:**

-   `lockTimestamps`: An array of normalized lock timestamps for the locked rEUL amounts to withdraw. These can be obtained using `IREUL.getLockedAmountsLockTimestamps(address)`
-   `allowRemainderLoss`:
    -   If `true`: Allows the withdrawal even if there are remainders that will be transferred to the configured receiver address (as per the lock schedule)
    -   If `false`: The withdrawal will revert if there are any remainder amounts that cannot be fully withdrawn

### Integration with RewardsClaimManager

This fuse must be registered with a `RewardsClaimManager` contract. The manager:

-   Provides access control (typically via `CLAIM_REWARDS` role)
-   Coordinates multiple reward claim operations
-   Receives the claimed EUL tokens

## Usage Example

```solidity
// 1. Get lock timestamps for the vault
uint256[] memory lockTimestamps = IREUL(rEUL).getLockedAmountsLockTimestamps(vaultAddress);

// 2. Prepare claim data
ClaimData memory claimData = ClaimData({
    lockTimestamps: lockTimestamps,
    allowRemainderLoss: true  // Set to false if you want to ensure no remainder loss
});

// 3. Create fuse action
FuseAction memory action = FuseAction({
    fuse: address(rewardEulerTokenClaimFuse),
    data: abi.encodeWithSelector(RewardEulerTokenClaimFuse.claim.selector, claimData)
});

// 4. Execute through RewardsClaimManager
RewardsClaimManager(managerAddress).claimRewards(calls);
```

## Checking Withdrawable Amounts

Before claiming, you can check how much EUL can be withdrawn:

```solidity
(uint256 accountAmount, uint256 remainderAmount) = IREUL(rEUL).getWithdrawAmountsByLockTimestamp(
    vaultAddress,
    lockTimestamp
);
```

-   `accountAmount`: The amount that can be unlocked and sent to the account
-   `remainderAmount`: The amount that will be transferred to the configured receiver address (if `allowRemainderLoss` is true)

## Security Considerations

1. **Access Control**: The `claim()` function should be called through `RewardsClaimManager` which enforces proper access control
2. **Balance Validation**: The fuse validates that the EUL balance of the rewards manager does not decrease after the operation
3. **Reentrancy**: This contract should be used in a context with proper reentrancy protection (provided by the vault system)
4. **Remainder Loss**: Setting `allowRemainderLoss` to `true` means some tokens may be sent to the configured receiver address instead of the rewards manager. Consider this when calculating expected rewards

## Events

```solidity
event RewardEulerTokenClaimFuseClaimed(address rewardsClaimManager, uint256 eulerRewardsManagerBalance);
```

Emitted when rewards are successfully claimed, including:

-   The address of the rewards claim manager that received the tokens
-   The amount of EUL tokens claimed

## Errors

-   `RewardEulerTokenClaimFuseInvalidAddress()`: Thrown when rEUL or EUL address is zero in constructor
-   `RewardEulerTokenClaimFuseRewardsClaimManagerNotSet()`: Thrown when RewardsClaimManager address is not set in the vault
-   `RewardEulerTokenClaimFuseInvalidBalanceAfter()`: Thrown when EUL balance decreases after claim operation

## Deployment

The constructor requires:

-   `rEUL_`: Address of the rEUL token contract (e.g., `0xf3e621395fc714B90dA337AA9108771597b4E696` on Ethereum mainnet)
-   `EUL_`: Address of the EUL token contract (e.g., `0xd9Fcd98c322942075A5C3860693e9f4f03AAE07b` on Ethereum mainnet)

## Related Contracts

-   `IREUL`: Interface for interacting with the rEUL token contract
-   `RewardsClaimManager`: Manager contract that coordinates reward claims
-   `PlasmaVaultLib`: Library providing access to vault storage and configuration

## References

-   [Euler rEUL Documentation](https://docs.euler.finance/EUL/reward-eul)
-   [rEUL Rewards Governance Proposal](https://docs.euler.finance/EUL/reward-eul#further-reading)

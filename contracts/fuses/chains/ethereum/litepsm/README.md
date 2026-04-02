# LitePSM Supply Fuse

Integration with [Sky LitePSM](https://developers.skyeco.com/guides/psm/litepsm/) for converting USDC to yield-bearing sUSDS via the LitePSMWrapper and sUSDS ERC4626 vault in IPOR Fusion PlasmaVault.

## Overview

LitePSMSupplyFuse enables PlasmaVault to convert idle USDC into yield-bearing sUSDS and back. sUSDS currently earns ~4% APY, making it significantly more capital-efficient than holding stagnant USDC. The Sky LitePSM converts USDC to USDS at a fixed 1:1 ratio (decimal adjustment only), currently with **zero fees** — meaning no slippage compared to ~0.3% on DEX swaps.

Governance-controlled fees (`tin` for selling, `tout` for buying) may be introduced in the future. The fuse includes fee guards (`allowedTin`/`allowedTout`) that revert if actual fees exceed the caller's specified threshold, protecting against unexpected fee changes.

### Architecture

```
┌─────────────────┐     ┌──────────────────────┐     ┌───────────────────────────┐
│   PlasmaVault   │────>│ LitePSMSupplyFuse    │────>│ LitePSMWrapper-USDS-USDC  │
│  (delegatecall) │     │ (validation + fees)  │     │ 0xA188EEC8F812...         │
└─────────────────┘     └──────────────────────┘     └───────────────────────────┘
                                │                              │
                                │                     sellGem (USDC -> USDS)
                                │                     buyGem  (USDS -> USDC)
                                v
                        ┌──────────────────┐
                        │  sUSDS (ERC4626) │
                        │  0xa3931d7187... │
                        └──────────────────┘
                          deposit / withdraw
```

## Balance & Accounting Dependency

**This is critical for correct vault accounting.**

This fuse converts USDC (the vault's underlying asset) into sUSDS. After `enter()`, USDC disappears from the vault's direct token balance. If sUSDS is not tracked by a balance fuse on a separate market, the vault's `totalAssets` will undercount, affecting share price and withdrawals.

**This fuse does NOT track balance itself** — use `ZeroBalanceFuse` on this fuse's market.

### Required Configuration

```
┌────────────────────────────────────────────────────────┐
│                      PlasmaVault                       │
│                                                        │
│  Market N (LitePSM):                                   │
│    ├── SupplyFuse:  LitePSMSupplyFuse                  │
│    └── BalanceFuse: ZeroBalanceFuse                    │
│                                                        │
│  Market M (sUSDS):                                     │
│    └── BalanceFuse: Erc4626BalanceFuse                 │
│                     or Erc20BalanceFuse                │
│                                                        │
│  Dependency Graph: Market N ──depends on──> Market M   │
└────────────────────────────────────────────────────────┘
```

- **Market N** (this fuse's market): Uses `ZeroBalanceFuse` because the fuse itself holds no assets — it moves USDC into sUSDS.
- **Market M** (sUSDS market): Must have `Erc4626BalanceFuse` or `Erc20BalanceFuse` configured with sUSDS as a substrate, plus a price feed for the underlying asset.
- **Dependency graph**: Market N must depend on Market M so that balance updates after `instantWithdraw` correctly reflect the sUSDS position change.

Without this configuration, `instantWithdraw` will leave the sUSDS market balance stale, potentially inflating `totalAssets`.

## Contracts

| Contract                | Description                                                          |
| ----------------------- | -------------------------------------------------------------------- |
| `LitePSMSupplyFuse.sol` | Main fuse contract with enter/exit logic (executed via delegatecall) |
| `ext/ILitePSM.sol`      | Interface for the LitePSMWrapper contract                            |

## Key Features

- **Zero-cost conversion**: LitePSM currently charges no fees (tin = tout = 0), enabling free USDC<->USDS conversion
- **Yield generation**: sUSDS earns ~4% APY vs idle USDC
- **Fee guards**: `allowedTin`/`allowedTout` parameters revert if governance fees exceed the caller's threshold
- **Slippage protection**: `minSharesOut` on enter, `minAmountOut` on exit
- **Instant withdraw**: Graceful failure with event emission for scheduled withdrawal flows
- **Transient storage**: Alternative enter/exit via transient storage for composability

## Data Structures

### Enter Data

```solidity
struct LitePSMSupplyFuseEnterData {
    uint256 amount;        // USDC amount to convert (6 decimals)
    uint256 allowedTin;    // Max tin fee (WAD-based), reverts if exceeded
    uint256 minSharesOut;  // Min sUSDS shares expected, reverts if fewer received
}
```

### Exit Data

```solidity
struct LitePSMSupplyFuseExitData {
    uint256 amount;        // USDC amount to receive (6 decimals)
    uint256 allowedTout;   // Max tout fee (WAD-based), reverts if exceeded
    uint256 minAmountOut;  // Min USDC expected, reverts if fewer received (ignored in instantWithdraw)
}
```

## Execution Flow

### Enter (USDC -> sUSDS)

```
1. Alpha calls PlasmaVault.execute() with LitePSMSupplyFuseEnterData
2. PlasmaVault delegatecalls LitePSMSupplyFuse.enter()
3. Fuse checks tin fee <= allowedTin (reverts if exceeded)
4. Fuse caps amount to available USDC balance
5. Fuse approves LitePSM and calls sellGem(vault, amount) — USDC -> USDS
6. Fuse approves sUSDS and calls deposit(usdsBalance, vault) — USDS -> sUSDS
7. Fuse validates sharesReceived >= minSharesOut (reverts if not)
8. Fuse emits LitePSMSupplyFuseEnter event
```

### Exit (sUSDS -> USDC)

```
1. Alpha calls PlasmaVault.execute() with LitePSMSupplyFuseExitData
2. PlasmaVault delegatecalls LitePSMSupplyFuse.exit()
3. Fuse checks tout fee <= allowedTout (reverts if exceeded)
4. Fuse computes USDS needed (including tout fee), caps to sUSDS availability
5. Fuse calls sUSDS.withdraw(usdsAmount, vault, vault) — sUSDS -> USDS
6. Fuse approves LitePSM and calls buyGem(vault, usdcAmount) — USDS -> USDC
7. Fuse validates usdcReceived >= minAmountOut (reverts if not)
8. Fuse emits LitePSMSupplyFuseExit event
```

### Instant Withdraw

Best-effort exit that never reverts on operational failures:
- Fee check failure emits `LitePSMSupplyFuseExitFailed` instead of reverting
- sUSDS withdraw failure emits event and returns
- buyGem failure deposits USDS back into sUSDS to maintain vault state
- No `minAmountOut` check (best-effort, does not revert on slippage)

#### Instant Withdraw Parameters

```
params[0] = amount in USDC (6 decimals)  — set by PlasmaVault at withdrawal time
params[1] = allowedTout (WAD-based)      — configured upfront during setup
```

#### Setup via `configureInstantWithdrawalFuses`

```solidity
import {InstantWithdrawalFusesParamsStruct} from "../../libraries/PlasmaVaultLib.sol";

// Configure LitePSM as an instant withdrawal path
InstantWithdrawalFusesParamsStruct[] memory fuses = new InstantWithdrawalFusesParamsStruct[](1);

bytes32[] memory litePsmParams = new bytes32[](2);
litePsmParams[0] = bytes32(0); // placeholder — amount is set at withdrawal time
litePsmParams[1] = bytes32(uint256(0)); // allowedTout — recommend 0 since tout is currently zero

fuses[0] = InstantWithdrawalFusesParamsStruct({
    fuse: address(litePsmSupplyFuse),
    params: litePsmParams
});

PlasmaVaultGovernance(plasmaVault).configureInstantWithdrawalFuses(fuses);
```

> **Note:** `params[1]` (`allowedTout`) controls the maximum tout fee the fuse will accept during instant withdrawals.
> Recommended value is `0` since tout is currently zero. If governance enables a tout fee in the future, this parameter must be updated to match or exceed the new fee, otherwise instant withdrawals will silently fail.

## Events

| Event                                                                             | Description                                    |
| --------------------------------------------------------------------------------- | ---------------------------------------------- |
| `LitePSMSupplyFuseEnter(address version, uint256 usdcAmount, uint256 usdsAmount)` | Emitted on successful enter                    |
| `LitePSMSupplyFuseExit(address version, uint256 usdcAmount, uint256 usdsAmount)`  | Emitted on successful exit                     |
| `LitePSMSupplyFuseExitFailed(address version, uint256 amount)`                    | Emitted when instant withdraw fails gracefully |

## Errors

| Error                                                                                  | Description                                  |
| -------------------------------------------------------------------------------------- | -------------------------------------------- |
| `LitePSMSupplyFuseFeeExceeded(uint256 actualFee, uint256 allowedFee)`                  | Tin/tout fee exceeds allowed threshold       |
| `LitePSMSupplyFuseInsufficientShares(uint256 receivedShares, uint256 minSharesOut)`    | sUSDS shares received below minimum on enter |
| `LitePSMSupplyFuseInsufficientAmountOut(uint256 receivedAmount, uint256 minAmountOut)` | USDC received below minimum on exit          |

## Market ID

This fuse operates on market `LITE_PSM = 48` (defined in `IporFusionMarkets.sol`).

## Constants

| Constant   | Value                                        | Description                         |
| ---------- | -------------------------------------------- | ----------------------------------- |
| `LITE_PSM` | `48`                                         | Market ID in `IporFusionMarkets`    |
| `USDC`     | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` | USDC token (Ethereum)               |
| `USDS`     | `0xdC035D45d973E3EC169d2276DDab16f1e407384F` | USDS token (Ethereum)               |
| `SUSDS`    | `0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD` | sUSDS ERC4626 vault (Ethereum)      |
| `LITE_PSM` | `0xA188EEC8F81263234dA3622A406892F3D630f98c` | LitePSMWrapper-USDS-USDC (Ethereum) |

## Security Considerations

1. **Stateless Fuse**: LitePSMSupplyFuse has no storage variables (executed via delegatecall)
2. **SafeERC20**: All token transfers use OpenZeppelin SafeERC20
3. **Fee Guards**: Tin/tout checked before execution, reverts if exceeded
4. **Slippage Protection**: `minSharesOut` and `minAmountOut` prevent unfavorable conversions
5. **Partial Failure Recovery**: If `buyGem` fails during instant withdraw, USDS is deposited back into sUSDS
6. **Decimal Safety**: Explicit `DECIMAL_CONVERSION` constant for USDC (6) <-> USDS (18) conversions

## Testing

```bash
# Run all LitePSM fuse tests
forge test --match-path "test/fuses/litepsm/*" -vv

# Run a specific test
forge test --match-test "testShouldEnterLitePSMSupply" -vvv
```

## References

- [Sky LitePSM Documentation](https://developers.skyeco.com/guides/psm/litepsm/)
- [IPOR Fusion Documentation](https://docs.ipor.io)

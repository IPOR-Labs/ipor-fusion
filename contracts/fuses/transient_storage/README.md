# Transient Storage Fuses (fuse chaining)

## Overview

The fuses in `contracts/fuses/transient_storage/` do not touch any external protocol. They move
`bytes32` values through EIP-1153 transient storage so that several fuses executed in **one**
`PlasmaVault.execute` call can pass results to each other without the caller knowing them in
advance: read a value on chain, convert it, feed it to the next fuse's `enterTransient()`.

Every fuse that supports chaining exposes `enterTransient()` / `exitTransient()`, which read
their inputs with `TransientStorageLib.getInputs(VERSION)` and write their results with
`TransientStorageLib.setOutputs(VERSION)`, keyed by the fuse's own address (`VERSION`).
Transient storage is cleared at the end of the transaction.

## Market Structure

The fuses hold no position, so they borrow market ids that already exist:

- **Market ID 7** (`ERC20_VAULT_BALANCE`) — `TransientStorageSetInputsFuse`,
  `TransientStorageChainReaderFuse`. The balance of market 7 is reported by the
  `Erc20BalanceFuse` of the [erc20 integration](../erc20/); these two fuses do not read it.
- **Market ID `type(uint256).max`** (`ZERO_BALANCE_MARKET`) — `TransientStorageMapperFuse`,
  registered with a `ZeroBalanceFuse` (always 0).

None of the three reads substrates.

## Architecture

### TransientStorageSetInputsFuse

`enter(TransientStorageSetInputsFuseEnterData)` — selector `0xcd1df474`

| Field          | Type          | Meaning                                                                                                   |
| -------------- | ------------- | --------------------------------------------------------------------------------------------------------- |
| `fuse`         | `address[]`   | Fuses whose transient inputs are set; a zero address reverts with `WrongFuseAddress`.                     |
| `inputsByFuse` | `bytes32[][]` | One input array per fuse, same order; lengths must match and no array may be empty (`WrongInputsLength`). |

Seeds the inputs of the fuses that will run later in the same `execute` call. Values are packed
with `TypeConversionLib.toBytes32` (addresses right-aligned, integers as `uint256`).

### TransientStorageChainReaderFuse

`enter(bytes data_)` — selector `0xd4734f4a`; `data_` is `abi.encode(ExternalCalls)`:

```solidity
struct ReadDataFromResponse {
    DataType dataType;
    uint256 bytesStart;
    uint256 bytesEnd;
}
struct ExternalCall {
    address target;
    bytes targetCalldata;
    ReadDataFromResponse[] readers;
}
struct ExternalCalls {
    ExternalCall[] calls;
    uint256 responseLength;
}
```

For every call the fuse performs a `staticcall` on `target` and, for every reader, copies the
bytes `[bytesStart, bytesEnd)` of the return data (at most 32 bytes, `DataTooLong`; within the
return data, `OutOfBounds`), converts them according to `dataType` (`DataType` from
`TypeConversionLib`: unsigned and signed integers of several widths, `ADDRESS`, `BOOL`,
`BYTES32`) and appends the result to its own **outputs**. `responseLength` must equal the total
number of readers. Outputs are cleared at the start of every `enter`.

### TransientStorageMapperFuse

`enter(TransientStorageMapperEnterData)` — selector `0xf250ffa1`; `items` is an array
(at most `MAX_ITEMS = 256`) of:

| Field              | Type                         | Meaning                                                                            |
| ------------------ | ---------------------------- | ---------------------------------------------------------------------------------- |
| `paramType`        | `TransientStorageParamTypes` | `INPUTS_BY_FUSE` or `OUTPUTS_BY_FUSE`: which array of the source to read.          |
| `dataFromAddress`  | `address`                    | Source fuse (non-zero).                                                            |
| `dataFromIndex`    | `uint256`                    | Index in the source array.                                                         |
| `dataFromType`     | `DataType`                   | How to interpret the source value.                                                 |
| `dataFromDecimals` | `uint256`                    | Decimals of the source value.                                                      |
| `dataToAddress`    | `address`                    | Destination fuse (non-zero); its inputs must already have `dataToIndex + 1` slots. |
| `dataToIndex`      | `uint256`                    | Index in the destination's inputs.                                                 |
| `dataToType`       | `DataType`                   | Type to convert to.                                                                |
| `dataToDecimals`   | `uint256`                    | Decimals to scale to.                                                              |

Conversion rules: same type and decimals, or an `UNKNOWN` type on either side, pass the raw
value; signed to `ADDRESS`, `BOOL` to `ADDRESS` and `ADDRESS` to signed are rejected
(`TransientStorageMapperFuseInvalidConversion`); negative values cannot become unsigned
(`...NegativeValueNotAllowed`); values that do not fit the target width revert
(`...ValueOutOfRange`); a decimal difference above `MAX_DECIMAL_DIFF = 77` reverts
(`...DecimalDifferenceTooLarge`), and a scaled value that overflows reverts
(`...DecimalOverflow` / `...SignedDecimalOverflow`).

## Typical chain inside one `execute`

1. `TransientStorageSetInputsFuse.enter` — seed constant inputs of the downstream fuses.
2. `TransientStorageChainReaderFuse.enter` — read balances, rates or ids on chain into outputs.
3. `TransientStorageMapperFuse.enter` — copy reader outputs (or another fuse's outputs) into the
   inputs of the next fuse, converting types and decimals.
4. `<ProtocolFuse>.enterTransient()` — the protocol fuse consumes its inputs and writes outputs,
   which a further mapper can forward.

## Balance Calculation

None. Market 7 is valued by the `Erc20BalanceFuse`; `ZERO_BALANCE_MARKET` by a
`ZeroBalanceFuse`. The transient fuses never hold tokens.

## Substrate Configuration

Not used: no fuse in this directory performs a substrate check.

## Price Oracle Setup

None.

## Roles

`ALPHA_ROLE` (200) executes the fuses through `PlasmaVault.execute`; `FUSE_MANAGER_ROLE` (300)
registers them. Market limits and price sources are irrelevant to these fuses.

## Deployed Contracts

No contract named after these fuses exists in the IPOR ABI registry (`IPOR-Labs/ipor-abi`
at commit `a0089cf`) on any chain; the catalog records them as `unknown`
(entries `ethereum-transient-storage-market-7` and
`ethereum-transient-storage-mapper-market-zero-balance` in [`catalog/fuses.json`](../../../catalog/fuses.json)).

## Tests

Local (no fork), run 2026-09-09 with the default profile: 151 tests, 0 failures.

- [`test/fuses/transient_storage/TransientStorageSetInputsFuse.t.sol`](../../../test/fuses/transient_storage/TransientStorageSetInputsFuse.t.sol) — 16
- [`test/fuses/transient_storage/TransientStorageChainReaderFuse.t.sol`](../../../test/fuses/transient_storage/TransientStorageChainReaderFuse.t.sol) — 25
- [`test/fuses/transient_storage/TransientStorageMapperFuse.t.sol`](../../../test/fuses/transient_storage/TransientStorageMapperFuse.t.sol) — 110
- [`test/transient_storage/TransientStorageLib.t.sol`](../../../test/transient_storage/TransientStorageLib.t.sol) — the library itself

`foundry.toml` sets `isolate = false` on purpose: with Forge's default `--isolate`, every
top-level call is a separate transaction and transient storage is wiped between the call that
sets inputs and the call that reads them.

## Security Notes

- **Same-transaction only.** Anything left in transient storage disappears with the
  transaction; a chain must be built inside one `execute` call.
- **The chain reader is a generic static-call primitive.** `ALPHA_ROLE` chooses the targets and
  calldata; only `staticcall` is used, so state cannot be changed through it, but the values it
  reads are trusted downstream without further checks.
- **Destination pre-sizing.** The mapper writes with `TransientStorageLib.setInput`, which
  requires the destination inputs to exist already (seed them with the set-inputs fuse).
- **Market ids are borrowed.** Registering the set-inputs/reader fuses on market 7 does not
  grant them any substrate, and they perform no substrate check.

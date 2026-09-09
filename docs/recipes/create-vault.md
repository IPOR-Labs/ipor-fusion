# Recipe: create a vault through the deployed factory

This is the end-to-end path for one vault created by the **already deployed**
Ethereum FusionFactory: inspect the deployment, plan the operation, simulate it
on a fork and verify what it produced. Every step here runs against a fork or a
local node; none of them broadcasts a transaction.

Follow it top to bottom. Nothing beyond this page and your own parameters is
needed.

## 0. Prerequisites

```bash
git submodule update --init --recursive
npm ci
npm run agent:doctor                       # toolchain, dependencies, submodules
npm run agent:doctor -- --rpc --chain 1 --block 25937526
```

The last command must report a healthy Ethereum provider with historical state.
It reads `ETHEREUM_PROVIDER_URL` from your environment or `.env`; see
[`../../.env.example`](../../.env.example). An archive-capable endpoint is
required — the pinned block is months old.

Pinned facts used below, all from
[`../deployments.md`](../deployments.md):

| Item             | Value                                        |
| ---------------- | -------------------------------------------- |
| Chain            | Ethereum, `1`                                |
| Deployment ID    | `ethereum-fusion-factory-cd05909c`           |
| Factory (proxy)  | `0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852` |
| Verification block | `25937526`                                 |

## 1. Inspect the deployment

```bash
npm run factory:inspect -- \
  --chain 1 \
  --deployment ethereum-fusion-factory-cd05909c \
  --block 25937526 \
  --caller 0x1111111111111111111111111111111111111111
```

Read three things from the report: the implementation matches the manifest, the
factory version is `8`, and `fees.effectiveForCaller` shows which packages your
caller would get. Fees are chosen by `msg.sender`, so inspect with the address
that will actually send the transaction.

## 2. Write and validate the input

Copy [`../../config/vaults/example.json`](../../config/vaults/example.json) and
change the parts that are yours: `caller`, `vault.owner`, the underlying token
with its `decimals`, the name, symbol, redemption delay and the fee package you
expect (index, source and its values including the recipient).

```bash
cp config/vaults/example.json my-vault.json
$EDITOR my-vault.json
npm run validate:vault-config -- my-vault.json
```

The units are in the field names: `*Seconds` is seconds, `*Bps` is basis points,
`decimals` is the token's own. See [`../vaults.md`](../vaults.md) for the full
field reference and the error codes.

## 3. Plan the operation

```bash
npm run vault:plan -- --config my-vault.json --block 25937526 --out plan.json
```

The plan contains the calldata, the target, the caller, `value: "0"`, the
implementation and version read at that block, and the fee package the factory
resolves for your caller. Check the calldata yourself:

```bash
cast decode-calldata "clone(string,string,address,uint256,address,uint256)" \
  "$(node -e 'console.log(require("./plan.json").transaction.data)')"
```

If the factory has been upgraded, or your fee package is not what you expected,
planning stops instead of producing an artifact.

## 4. Simulate it on a fork

```bash
npm run vault:simulate -- --plan plan.json --out simulation.json
```

Expect `status: "success"` and `result.verification.ok: true`. The command forks
the chain at the plan's block with `anvil`, sends the exact calldata as your
caller, and then verifies the created vault: component code, wiring, owner role,
redemption delay, decimals and the fee package. A creation that succeeds but
whose state disagrees with your input is reported as `unverified`.

The addresses in the report exist only inside that ephemeral fork.

## 5. Verify a real creation

When the transaction has actually been sent — by whoever is authorised to send
it, which is outside this repository — resolve its result from the receipt:

```bash
npm run vault:verify -- --chain 1 --tx <transaction-hash> --config my-vault.json --json
```

Statuses to act on: `success`, `unverified`, `reverted`, `pending`, `not-final`.
A `pending` result means the transaction exists — **do not send the creation
again**, or you will create a second vault.

You can rehearse this step without a real transaction, against a local fork:

```bash
anvil --fork-url "$ETHEREUM_PROVIDER_URL" --fork-block-number 25937526 --port 8545 &
cast rpc --rpc-url http://127.0.0.1:8545 anvil_impersonateAccount 0x1111111111111111111111111111111111111111
cast rpc --rpc-url http://127.0.0.1:8545 anvil_setBalance 0x1111111111111111111111111111111111111111 0xde0b6b3a7640000
cast rpc --rpc-url http://127.0.0.1:8545 eth_sendTransaction \
  "{\"from\":\"0x1111111111111111111111111111111111111111\",\"to\":\"0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852\",\"data\":\"$(node -e 'console.log(require("./plan.json").transaction.data)')\",\"value\":\"0x0\"}"
npm run vault:verify -- --chain 1 --tx <hash from the previous line> --rpc-url http://127.0.0.1:8545 --config my-vault.json
kill %1
```

## What this recipe does not give you

- **A configured strategy.** The vault exists, is owned and has its fee package;
  it has no fuses, no balance fuses, no substrates, no market limits and no
  price feeds. Deposits and strategy operations need that configuration first.
- **A sent transaction.** Signing and broadcasting are a separate, authorised
  path. Everything above stops at a reviewed artifact.
- **Another network or factory.** Only the Ethereum FusionFactory entry is
  `verified`. Another chain needs its own manifest, ABI, verification report and
  compatibility test before these commands accept it.
- **A guarantee over time.** Plans and reports are pinned to a block. If the
  factory is upgraded or fee packages change, re-run from step 1 — the tools
  refuse to reuse a stale plan rather than adapting silently.

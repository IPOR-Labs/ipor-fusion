# Troubleshooting the factory and vault path

Every symptom below was produced in this repository, by a command in it. Each
entry gives the exact message, what it means, and the command that confirms the
cause. None of them tells you what to change — the fix depends on what the check
reveals.

The commands assume `ETHEREUM_PROVIDER_URL` is set (see
[`../.env.example`](../.env.example)); no output here contains a URL, and neither
does any tool's.

## Environment and RPC

### `RPC_UNAVAILABLE: ETHEREUM_PROVIDER_URL is not set`

The variable is missing from the environment and from `.env`. Confirm which
variables the tooling expects and which are present:

```bash
npm run agent:doctor
```

The doctor reports the **names** of the variables it looked for, never values.

### `CHAIN_MISMATCH: requested chain 1, provider reports 42161`

The endpoint behind the variable serves another network. Ask it directly:

```bash
cast chain-id --rpc-url "$ETHEREUM_PROVIDER_URL"
```

### `HISTORICAL_STATE_UNAVAILABLE: block 25937526 is unavailable`

The endpoint is alive but is not an archive node, or it has pruned that block.
Separate "no state" from "no node":

```bash
npm run agent:doctor -- --rpc --chain 1 --block 25937526
cast block 25937526 --rpc-url "$ETHEREUM_PROVIDER_URL" --field hash
cast code --rpc-url "$ETHEREUM_PROVIDER_URL" --block 25937526 \
  0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852 | head -c 20
```

A block header that resolves while `eth_getCode` at that block returns `0x` is a
pruned archive, not a missing block.

### `FORK_UNAVAILABLE: anvil did not become ready in time`

`vault:simulate` could not start its fork. Run anvil by hand with the same block
and watch its output:

```bash
anvil --fork-url "$ETHEREUM_PROVIDER_URL" --fork-block-number 25937526 --port 8545
```

Rate limiting on the provider is the usual cause, and it shows up there.

## Deployment identity and ABI

### `IMPLEMENTATION_MISMATCH: manifest expects 0xf19C…63f5, block 23831825 has 0x…`

The proxy pointed at a different implementation at the block you asked for. This
is real: the pilot factory was upgraded between block `23831825` and `25937526`.
Read the ERC-1967 slot at both blocks:

```bash
for block in 23831825 25937526; do
  cast storage --rpc-url "$ETHEREUM_PROVIDER_URL" --block $block \
    0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852 \
    0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc
done
```

A plan is only valid for the implementation it was built against; the tools
refuse rather than adapting.

### `UNSUPPORTED_FACTORY_VERSION: manifest recorded version 8, block … reports 9`

The deployment was upgraded after the manifest was verified. Confirm with the
factory itself, then compare against the manifest:

```bash
cast call --rpc-url "$ETHEREUM_PROVIDER_URL" 0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852 \
  "getFusionFactoryVersion()(uint256)"
node -e 'console.log(require("./deployments/1/factories.json").deployments[0].interface.reportedVersion)'
```

### `UNSUPPORTED_FACTORY_VERSION: ABI does not contain exactly one <name>`

The recorded ABI does not describe the deployed code. Check the ABI's hash
against the manifest before anything else:

```bash
npm run validate:deployments
npm run validate:pilot-abi
```

### `FailedInnerCall()` from `PlasmaVault.execute`

A fuse delegatecall reverted. The most common cause on the pilot is encoding the
**source's** interface against an **older deployed** fuse. Probe the deployed
selectors:

```bash
CODE=$(cast code --rpc-url "$ETHEREUM_PROVIDER_URL" --block 25937526 \
  0x12FD0EE183c85940CAedd4877f5d3Fc637515870)
for sig in "enter((address,uint256,uint256))" "enter((address,uint256))"; do
  sel=$(cast sig "$sig"); case "$CODE" in *"${sel:2}"*) echo "PRESENT $sel $sig";; *) echo "absent  $sel $sig";; esac
done
```

The pilot's deployed supply fuse answers `enter((address,uint256))` `0xd5ee7916`
and does **not** carry the checkout's three-field struct — see
[`fuse-catalog.md`](fuse-catalog.md).

### Deployed fuses whose ABI differs from this checkout

The catalog records every deployed fuse whose runtime code lacks a selector
this checkout describes (`matchesCurrentSource: false` with a note). Known
cases, all read at the blocks the catalog names:

| Deployment                                              | Deployed signature                                    | This checkout                                               |
| ------------------------------------------------------- | ----------------------------------------------------- | ----------------------------------------------------------- |
| Ethereum `SupplyFuseErc4626Market1` `0x12FD0EE1…`       | `enter((address,uint256))`, `exit((address,uint256))` | three-field structs with `minSharesOut` / `maxSharesBurned` |
| Base `SupplyFuseFluidInstadappPoolFToken` `0x15A1e295…` | `enter((address,uint256))`, `exit((address,uint256))` | the same three-field `Erc4626SupplyFuse` structs            |

Probe before encoding, as shown above, and read the entry's `deployments`
notes in [`../catalog/fuses.json`](../catalog/fuses.json).

## Roles

### `MISSING_ROLE: 0x… does not hold OWNER_ROLE (1), required for step "grant-roles"`

The address you are configuring with is not the vault's owner. Ask the access
manager who holds what:

```bash
AM=$(cast call --rpc-url http://127.0.0.1:8545 <vault> "getAccessManagerAddress()(address)")
cast call --rpc-url http://127.0.0.1:8545 $AM "hasRole(uint64,address)(bool,uint32)" 1 <address>    # OWNER
cast call --rpc-url http://127.0.0.1:8545 $AM "hasRole(uint64,address)(bool,uint32)" 100 <address>  # ATOMIST
cast call --rpc-url http://127.0.0.1:8545 $AM "hasRole(uint64,address)(bool,uint32)" 200 <address>  # ALPHA
cast call --rpc-url http://127.0.0.1:8545 $AM "hasRole(uint64,address)(bool,uint32)" 300 <address>  # FUSE_MANAGER
```

The role numbers and who administers them are in
[`roles-and-permissions.md`](roles-and-permissions.md).

### `AccessManagedUnauthorized(0x…)` from a vault call

The caller lacks the role for that specific function, not for the vault as a
whole. Check the role of the function's guard in
[`roles-and-permissions.md`](roles-and-permissions.md), then confirm with
`hasRole` as above. A vault call that reverts for the _owner_ usually means the
owner never granted itself the operational role — ownership and operation are
separate roles by design.

## Fees

### `FEE_PACKAGE_MISMATCH: managementFeeBps: config expects 5, factory reports 7`

The package at that index is not what the input expected. Read both lists as the
caller that will actually send the transaction — the factory selects by
`msg.sender`:

```bash
npm run factory:inspect -- --chain 1 --deployment ethereum-fusion-factory-cd05909c \
  --block 25937526 --caller <the real caller>
```

### `FEE_PACKAGE_MISMATCH: config expects the dao-global list …, the factory uses business-client`

That caller has its own packages configured, which shadow the global list and are
indexed independently. The inspect report's `fees.effectiveForCaller.isCustom`
says which list applies; a different caller gets a different answer.

## Substrates, markets and oracle

### `SUBSTRATE_ASSET_MISMATCH: 0x… holds 0x6B17…1d0F, the vault's asset is 0xA0b8…eB48`

The ERC4626 vault you granted is denominated in another token than the Plasma
Vault's asset, so the supply fuse could never move funds into it:

```bash
cast call --rpc-url "$ETHEREUM_PROVIDER_URL" <erc4626 vault> "asset()(address)"
cast call --rpc-url "$ETHEREUM_PROVIDER_URL" <plasma vault> "asset()(address)"
```

### `Erc4626SupplyFuseUnsupportedVault("enter", 0x…)`

The vault address in the action is not a granted substrate of that market. List
what is granted:

```bash
cast call --rpc-url http://127.0.0.1:8545 <plasma vault> \
  "getMarketSubstrates(uint256)(bytes32[])" 100001
```

Substrates are a full replacement list, not an append: granting again with a
shorter list revokes what is missing from it.

### `MarketLimitExceeded(100001, 59999999999, 49999999999)`

The third value is the limit the vault computed, the second is what the action
would have put into the market. A limit that comes out as `0` almost always means
the limit was configured in basis points instead of WAD — `1e18` is 100%:

```bash
cast call --rpc-url http://127.0.0.1:8545 <plasma vault> "getMarketLimit(uint256)(uint256)" 100001
```

### `PRICE_SOURCE_MISSING: the vault's price manager cannot price 0x…`

The balance fuse would not be able to value the market. Ask the vault's own price
manager, then the middleware behind it:

```bash
PM=$(cast call --rpc-url http://127.0.0.1:8545 <plasma vault> "getPriceOracleMiddleware()(address)")
cast call --rpc-url http://127.0.0.1:8545 $PM "getAssetPrice(address)(uint256,uint256)" <asset>
cast call --rpc-url http://127.0.0.1:8545 $PM "getSourceOfAssetPrice(address)(address)" <asset>
```

`getSourceOfAssetPrice` returning the zero address is **not** proof that the
asset is unpriceable: the vault's price manager falls back to the middleware it
points at, which is why `getAssetPrice` can answer for USDC while the manager
itself holds no source of its own. Trust the price, not the source address.

A market whose balance fuse cannot price its assets mis-values the vault; adding
the balance fuse without the price source is worse than adding neither.

## Transactions and results

### `TRANSACTION_UNKNOWN` from `vault:verify`

The endpoint has never seen that hash. It may be the wrong network, the wrong
endpoint, or a transaction that was never sent. Check on the network you meant:

```bash
cast tx <hash> --rpc-url "$ETHEREUM_PROVIDER_URL" --json | head -c 200
```

### `status: "pending"` from `vault:verify`

The transaction exists but is not in a block. **Do not send the creation again** —
a second successful transaction creates a second vault. Watch the nonce instead:

```bash
cast nonce <sender> --rpc-url "$ETHEREUM_PROVIDER_URL"
cast nonce <sender> --rpc-url "$ETHEREUM_PROVIDER_URL" --block pending
```

### `status: "reverted"` from `vault:verify`

The transaction was mined and failed; no vault exists. Replay it locally at the
block before it to see the revert:

```bash
cast run <hash> --rpc-url "$ETHEREUM_PROVIDER_URL"
```

### `FOREIGN_CREATION_EVENT` / `CREATION_EVENT_ABSENT`

An event with the creation signature was emitted by a contract that is not the
registered factory, or no such event is in the receipt at all. The emitter is the
whole point of the check:

```bash
npm run vault:verify -- --chain 1 --tx <hash> --json | \
  node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).result?.foreignEventsIgnored))'
```

### `SIMULATION_INCONSISTENT`

The addresses read from the call's return value and from the emitted event do not
agree. That is a contradiction in what the chain reported, not a tolerance
question — stop and inspect the simulation report's `result.created` and
`result.creationEvent` before doing anything else.

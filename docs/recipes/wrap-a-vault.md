# Recipe: wrap a pilot vault

A **wrapper** is a separate ERC-4626 token around an existing Plasma Vault, with
its own name, its own owner and its own fees. It does not change the vault it
wraps, and it does not inherit the vault's roles.

This recipe uses the deployed `WrappedPlasmaVaultFactory` on Ethereum — the
**plain** variant. The whitelist variant is a different deployment with different
access rules and is out of scope here (see the last section).

Start from a vault created by [`create-vault.md`](create-vault.md).

## What the factory needs

| Field                       | Meaning                                                                |
| --------------------------- | ----------------------------------------------------------------------- |
| `name_`, `symbol_`          | The wrapper's own ERC-20 identity, unrelated to the vault's.            |
| `plasmaVault_`              | The vault being wrapped. Zero is refused.                               |
| `wrappedPlasmaVaultOwner_`  | The wrapper's owner — the only address that may configure its fees.     |
| `managementFeeAccount_`     | Where the wrapper's management fee goes. Zero is refused.               |
| `managementFeePercentage_`  | **`10000` = 100%**, so `100` is 1%. Above `10000` is refused.           |
| `performanceFeeAccount_`    | Where the wrapper's performance fee goes. Zero is refused.              |
| `performanceFeePercentage_` | Same unit as the management fee.                                        |

That fee unit is the wrapper's own. It is not the vault's fee package, and it is
not the WAD fraction used for market limits.

## Create one

```bash
anvil --fork-url "$ETHEREUM_PROVIDER_URL" --fork-block-number 25937526 --port 8545 &
cast rpc --rpc-url http://127.0.0.1:8545 anvil_impersonateAccount <your caller>
cast rpc --rpc-url http://127.0.0.1:8545 anvil_setBalance <your caller> 0xde0b6b3a7640000

cast send --rpc-url http://127.0.0.1:8545 --unlocked --from <your caller> \
  0xb17a9D70a73e0DcFfc12563Bcc0c1D68F3F353C8 \
  "create(string,string,address,address,address,uint256,address,uint256)" \
  "Wrapped Pilot USDC" "wUSDC" <vault> <wrapper owner> <management fee account> 100 <performance fee account> 1000
```

Creation is permissionless, exactly like the vault's `clone`.

## Check what you got

```bash
cast call --rpc-url http://127.0.0.1:8545 <wrapper> "PLASMA_VAULT()(address)"
cast call --rpc-url http://127.0.0.1:8545 <wrapper> "asset()(address)"
cast call --rpc-url http://127.0.0.1:8545 <wrapper> "owner()(address)"
cast call --rpc-url http://127.0.0.1:8545 <wrapper> "getManagementFeeData()((address,uint16,uint32))"
cast call --rpc-url http://127.0.0.1:8545 <wrapper> "getPerformanceFeeData()((address,uint16))"
```

`PLASMA_VAULT()` must be the vault you asked for and `asset()` must equal that
vault's asset. If either differs, you wrapped something else.

## Permissions are the wrapper's own

Only `owner()` of the **wrapper** may call `configureManagementFee` or
`configurePerformanceFee`. The wrapped vault's owner cannot — wrapping does not
hand the vault's governance any authority over the wrapper, and it does not hand
the wrapper's owner any authority over the vault.

The whole path is covered by a fork test against the unchanged deployment:

```bash
npm run test:fork -- --chain 1 --suite deployed-wrapped-vault-factory --block 25937526
```

[`WrappedPlasmaVaultFactoryEthereum.t.sol`](../../test/deployed-factories/WrappedPlasmaVaultFactoryEthereum.t.sol)
creates a vault through the deployed FusionFactory, wraps it, checks the binding,
the identity, the owner and both fee configurations, then proves that the vault's
owner is refused and the wrapper's owner is not, and that a zero vault address
and a fee above 100% are rejected.

## The whitelist variant is a different deployment

`WhitelistWrappedPlasmaVaultFactoryProxy`
(`0x30378C767A5F2c444287bCbdbdB29a73AF125151`) creates wrappers whose deposits
are restricted. It is a **separate** factory with separate rules: it has its own
ABI, its own manifest entry and its own compatibility test to write. Do not
reuse this recipe's addresses or conclusions for it — the registry treats the two
variants as different deployments precisely so that this stays visible.

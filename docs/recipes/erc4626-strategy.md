# Recipe: run the ERC4626 pilot strategy end to end

This recipe takes the vault from [`create-vault.md`](create-vault.md) and puts it
to work: configure the catalogued ERC4626 market, deposit, supply into the
external vault, come back out and redeem. Everything happens on a fork.

Read [`create-vault.md`](create-vault.md) first — this page starts from a created
vault.

## What the pilot is

| Item                | Value                                                            |
| ------------------- | ----------------------------------------------------------------- |
| Catalog entry       | `ethereum-erc4626-market-100001` ([fuse-catalog.md](../fuse-catalog.md)) |
| Market              | `100001` (`ERC4626_0001`)                                         |
| Action fuse         | `0x12FD0EE183c85940CAedd4877f5d3Fc637515870` (deployed, unchanged) |
| Balance fuse        | `0x2C10C36028C430f445a4bA9f7Dd096a5DcC75d5e` (deployed, unchanged) |
| Substrate           | `0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB` — Steakhouse USDC     |
| Vault asset         | USDC                                                              |

The substrate must be an ERC4626 vault denominated in **the Plasma Vault's own
asset**; the supply fuse deposits that asset, so a DAI-denominated vault on a
USDC Plasma Vault is refused.

## 1. Configure the market

```bash
anvil --fork-url "$ETHEREUM_PROVIDER_URL" --fork-block-number 25937526 --port 8545 &
npm run vault:configure -- --config config/strategies/erc4626-usdc.json \
  --vault <vault address> --rpc-url http://127.0.0.1:8545 --dry-run
npm run vault:configure -- --config config/strategies/erc4626-usdc.json \
  --vault <vault address> --rpc-url http://127.0.0.1:8545
```

Four steps run as the operators that hold the roles: grant roles, register the
two fuses, grant the substrate, set and activate the market limit. See
[vaults.md](../vaults.md) for the step table and every refusal.

**The market limit is a WAD fraction**, not basis points: `1e18` is 100% of the
vault's assets and the example caps the market at 50% (`5e17`). A value in basis
points would set a limit of effectively zero and every supply action would revert
with `MarketLimitExceeded`.

## 2. Roles for the money path

Beyond configuration, two roles matter for the cycle itself:

- `ALPHA_ROLE` executes `PlasmaVault.execute([FuseAction])` — nobody else can
  move funds into or out of the market;
- a fresh vault is private, so a depositor needs `WHITELIST_ROLE`, or the atomist
  converts the vault to public.

## 3. Encode against the deployed fuse, not the source

The deployed supply fuse is an **older version** than this checkout:

| Where                  | Enter                                      | Exit                                     |
| ---------------------- | ------------------------------------------- | ----------------------------------------- |
| This checkout's source | `enter((address,uint256,uint256))` `0x41b11ae7` | `exit((address,uint256,uint256))` `0x8467bd30` |
| The deployed fuse      | `enter((address,uint256))` `0xd5ee7916`     | `exit((address,uint256))` `0x92876ac8`    |

Encoding the source's three-field struct against the deployed fuse reverts inside
the delegatecall with `FailedInnerCall()`. Check the selectors in the deployment's
runtime code before encoding:

```bash
cast code --rpc-url http://127.0.0.1:8545 0x12FD0EE183c85940CAedd4877f5d3Fc637515870 \
  | grep -o "$(cast sig 'enter((address,uint256))' | cut -c3-)"
```

## 4. The full cycle, as a test

The whole path is covered by one fork test against the unchanged deployment:

```bash
npm run test:fork -- --chain 1 --suite deployed-factory --block 25937526
```

[`Erc4626StrategyLifecycleEthereum.t.sol`](../../test/deployed-factories/Erc4626StrategyLifecycleEthereum.t.sol)
does, in order:

1. creates a USDC vault through the unchanged factory;
2. configures roles, both fuses, the substrate and a 50% market limit;
3. deposits 100 000 USDC as a whitelisted depositor;
4. supplies 40 000 USDC into Steakhouse USDC as the alpha, checking that shares
   arrive, that the idle balance drops by exactly that amount and that total
   assets are unchanged by the move;
5. exits the position and checks the funds came back;
6. redeems every share and checks the depositor is whole.

Accounting is compared with a tolerance of 1 USDC on 100 000 (ERC4626 rounding on
the way in and out). Two things in it exist only in a test and are marked as such
in the source: `deal` gives the depositor USDC, and one `vm.warp` passes the
vault's own redemption delay. On a network you wait the delay out.

## Limits of this recipe

- One market, one substrate, one protocol. Another integration needs its own
  catalog entry, its own verified fuse deployments and its own run.
- No yield is demonstrated: the fork is pinned to one block, so the position is
  entered and exited at the same share price.
- Nothing here signs or broadcasts. Configuration on a network is four
  transactions from the role holders, and the money path is theirs too.

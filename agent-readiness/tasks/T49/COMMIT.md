# T49 — commit do wykonania ręcznie na hoście

## Komunikat

```
feat(price-feed): T49 support one deployed feed factory

Register the deployed Ethereum ERC4626 price feed factory as a second verified
entry: its verified ABI with provenance, a manifest entry naming the price oracle
middleware as a required dependency, and a verification report pinned to block
25937526.

Add a deployed-usage test that creates a feed for Steakhouse USDC through the
unchanged factory and checks that it points at that vault, reports 18 decimals
and returns a price equal to the value recomputed from convertToAssets and the
middleware's USDC price, while a non-ERC4626 address is rejected.

The entry records what is not known: this factory has no version getter, and the
implementation's verified compiler metadata was not captured.
```

Ten sam tekst jest w `agent-readiness/tasks/T49/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/PLAN.md` | checkbox T49 → `[x]` |
| `agent-readiness/STATUS.md` | wiersz T49 → ready-for-commit |
| `agent-readiness/tasks/T49/*` | nowe — LOG, COMMIT, komunikat, runs |
| `abi/erc4626-price-feed-factory-ethereum-0xe08aff.../ERC4626PriceFeedFactory.abi.json` | nowy — zweryfikowane ABI |
| `abi/erc4626-price-feed-factory-ethereum-0xe08aff.../provenance.json` | nowy — pochodzenie |
| `deployments/1/factories.json` | zmieniony — drugi wpis, `verified` |
| `deployments/reports/ethereum-erc4626-price-feed-factory-f58fcce9-25937526.json` | nowy — raport |
| `test/deployed-factories/Erc4626PriceFeedFactoryEthereum.t.sol` | nowy — 2 testy |
| `config/test-suites.json` | zmieniony — grupa `deployed-price-feed-factory` |
| `docs/deployments.md` | zmieniony — sekcja o drugim wpisie |

## Pliki w `git status`, które NIE należą do tego commita

- zmiany T25–T48. `deployments/1/factories.json`, `config/test-suites.json` i
  `docs/deployments.md` są wspólne z wcześniejszymi zadaniami serii.

## Komendy dla hosta

```bash
cd ~/repos/ipor-fusion
git add agent-readiness/PLAN.md agent-readiness/STATUS.md agent-readiness/tasks/T49/
git add abi/erc4626-price-feed-factory-ethereum-0xe08aff4910fb61acc2eacb03b0a6132b01d1aa61/
git add deployments/1/factories.json deployments/reports/ethereum-erc4626-price-feed-factory-f58fcce9-25937526.json
git add test/deployed-factories/Erc4626PriceFeedFactoryEthereum.t.sol config/test-suites.json docs/deployments.md
git status --short
git commit -F agent-readiness/tasks/T49/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T49 na `committed <hash>`.

# T36 — commit do wykonania ręcznie na hoście

## Komunikat

```
test(vault): T36 cover the pilot strategy asset lifecycle

Add a deployed-usage fork test that creates a vault through the unchanged
factory, configures the catalogued ERC4626 market with the deployed fuses, then
deposits, supplies into Steakhouse USDC as the alpha, exits and redeems, with
total assets preserved within 1 USDC on 100000.

The test showed two things the tooling had wrong: market limits are a WAD
fraction, not basis points, and the deployed supply fuse takes (vault, amount)
without the current source's slippage bounds. Both are fixed in the strategy
configuration input and recorded in the catalog.

Add docs/recipes/erc4626-strategy.md and classify the new suite, with its
test-only funding and time travel named in the catalog entry.
```

Ten sam tekst jest w `agent-readiness/tasks/T36/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/PLAN.md` | checkbox T36 → `[x]` |
| `agent-readiness/STATUS.md` | wiersz T36 → ready-for-commit |
| `agent-readiness/tasks/T36/*` | nowe — LOG, COMMIT, komunikat, runs |
| `test/deployed-factories/Erc4626StrategyLifecycleEthereum.t.sol` | nowy — test cyklu środków |
| `config/test-suites.json` | zmieniony — nowa suita `deployed-factory-ethereum-erc4626-strategy` |
| `docs/recipes/erc4626-strategy.md` | nowy — recepta |
| `docs/README.md` | zmieniony — indeks |
| `config/strategies/strategy-configuration.schema.json` | zmieniony — limit w WAD |
| `config/strategies/erc4626-usdc.json` | zmieniony — limit w WAD |
| `tools/configure-strategy.mjs` | zmieniony — limit w WAD |
| `tools/test-configure-strategy.mjs` | zmieniony — asercja limitu w WAD |
| `docs/vaults.md` | zmieniony — jednostka limitu |
| `catalog/fuses.json` | zmieniony — wdrożony fuse: `matchesCurrentSource: false` + selektory |
| `docs/fuse-catalog.md` | zmieniony — dlaczego `interface` i `deployments` są rozdzielone |

## Pliki w `git status`, które NIE należą do tego commita

- zmiany T25–T35. `config/test-suites.json` jest wspólny z T25, a pliki strategii
  i katalogu z T33–T35 (poprawki wynikają wprost z tego testu).

## Komendy dla hosta

```bash
cd ~/repos/ipor-fusion
git add agent-readiness/PLAN.md agent-readiness/STATUS.md agent-readiness/tasks/T36/
git add test/deployed-factories/Erc4626StrategyLifecycleEthereum.t.sol config/test-suites.json
git add docs/recipes/erc4626-strategy.md docs/README.md docs/vaults.md docs/fuse-catalog.md
git add config/strategies/ tools/configure-strategy.mjs tools/test-configure-strategy.mjs catalog/fuses.json
git status --short
git commit -F agent-readiness/tasks/T36/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T36 na `committed <hash>`.

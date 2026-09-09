# T50 — commit do wykonania ręcznie na hoście

## Komunikat

```
feat(wrapper): T50 support one deployed wrapper variant

Register the deployed Ethereum WrappedPlasmaVaultFactory — the plain variant —
with its ABI and provenance, a manifest entry, a verification report at block
25937526 and docs/recipes/wrap-a-vault.md.

The deployed-usage test wraps a vault created by the pilot factory and checks the
binding to that vault and its asset, the wrapper's own name, symbol, owner and
both fee configurations, that only the wrapper's owner may reconfigure it — the
wrapped vault's owner is refused — and that a zero vault or a fee above 100% is
rejected.

The whitelist variant is a different deployment and is deliberately left out,
named in the manifest provenance, the report and the recipe.
```

Ten sam tekst jest w `agent-readiness/tasks/T50/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/PLAN.md` | checkbox T50 → `[x]` |
| `agent-readiness/STATUS.md` | wiersz T50 → ready-for-commit |
| `agent-readiness/tasks/T50/*` | nowe — LOG, COMMIT, komunikat, runs |
| `abi/wrapped-plasma-vault-factory-ethereum-0x3f68a6.../WrappedPlasmaVaultFactory.abi.json` | nowy — ABI z checkoutu |
| `abi/wrapped-plasma-vault-factory-ethereum-0x3f68a6.../provenance.json` | nowy — pochodzenie i granice dowodu |
| `deployments/1/factories.json` | zmieniony — trzeci wpis |
| `deployments/reports/ethereum-wrapped-plasma-vault-factory-b17a9d70-25937526.json` | nowy — raport |
| `test/deployed-factories/WrappedPlasmaVaultFactoryEthereum.t.sol` | nowy — 3 testy |
| `config/test-suites.json` | zmieniony — grupa `deployed-wrapped-vault-factory` |
| `docs/recipes/wrap-a-vault.md` | nowy — recepta |
| `docs/README.md` | zmieniony — indeks |

## Pliki w `git status`, które NIE należą do tego commita

- zmiany T25–T49. `deployments/1/factories.json`, `config/test-suites.json` i
  `docs/README.md` są wspólne z wcześniejszymi zadaniami serii.

## Komendy dla hosta

```bash
cd ~/repos/ipor-fusion
git add agent-readiness/PLAN.md agent-readiness/STATUS.md agent-readiness/tasks/T50/
git add abi/wrapped-plasma-vault-factory-ethereum-0x3f68a6a4fca2e6b85d041a53eb4090f6ac3311f5/
git add deployments/1/factories.json deployments/reports/ethereum-wrapped-plasma-vault-factory-b17a9d70-25937526.json
git add test/deployed-factories/WrappedPlasmaVaultFactoryEthereum.t.sol config/test-suites.json
git add docs/recipes/wrap-a-vault.md docs/README.md
git status --short
git commit -F agent-readiness/tasks/T50/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T50 na `committed <hash>`.

# T33 — commit do wykonania ręcznie na hoście

## Komunikat

```
feat(catalog): T33 describe the ERC4626 pilot integration

Add catalog/fuses.json with its schema and one entry: the generic ERC4626
integration on market 100001, with the enter/exit data ABI and field meanings,
the substrate shape and how it is granted and checked, what the balance fuse
prices and in which unit, the roles each configuration step needs, and the test
suites.

The two deployed fuses are recorded as observed at Ethereum block 25937526 with
their code hash and reported MARKET_ID; the balance fuse reverts on VERSION(),
so it is marked as not matching the current source rather than as ready to use.

validate:catalog enforces those evidence rules and 13 tests cover them.
```

Ten sam tekst jest w `agent-readiness/tasks/T33/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/PLAN.md` | checkbox T33 → `[x]` |
| `agent-readiness/STATUS.md` | wiersz T33 → ready-for-commit |
| `agent-readiness/tasks/T33/*` | nowe — LOG, COMMIT, komunikat, runs |
| `catalog/fuses.schema.json` | nowy — schemat katalogu |
| `catalog/fuses.json` | nowy — pozycja pilotażowa |
| `tools/validate-catalog.mjs` | nowy — walidator |
| `tools/test-validate-catalog.mjs` | nowy — 13 testów |
| `docs/fuse-catalog.md` | nowy — opis katalogu i poziomów dowodu |
| `docs/README.md` | zmieniony — indeks i lista wyjątków |
| `.gitignore` | zmieniony — `!docs/fuse-catalog.md` |
| `package.json` | zmieniony — `validate:catalog`, `validate:catalog:test` |

## Pliki w `git status`, które NIE należą do tego commita

- zmiany T25–T32. `.gitignore`, `docs/README.md` i `package.json` są wspólne z
  wcześniejszymi zadaniami serii.

## Komendy dla hosta

```bash
cd ~/repos/ipor-fusion
git add agent-readiness/PLAN.md agent-readiness/STATUS.md agent-readiness/tasks/T33/
git add catalog/ tools/validate-catalog.mjs tools/test-validate-catalog.mjs
git add docs/fuse-catalog.md docs/README.md .gitignore package.json
git status --short
git commit -F agent-readiness/tasks/T33/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T33 na `committed <hash>`.

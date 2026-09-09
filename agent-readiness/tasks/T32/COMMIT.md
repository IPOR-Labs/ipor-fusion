# T32 — commit do wykonania ręcznie na hoście

## Komunikat

```
docs(vault): T32 add the deployed-factory creation recipe

Add docs/recipes/create-vault.md, which walks from a fresh checkout to a
verified vault on a fork: doctor, inspect, write and validate the input, plan,
decode the calldata, simulate with verification, and resolve a real creation
from its receipt.

The whole recipe was executed as written, with a changed name, symbol and
redemption delay, ending in a simulation with all checks passing and a fork
transaction verified through vault:verify.
```

Ten sam tekst jest w `agent-readiness/tasks/T32/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/PLAN.md` | checkbox T32 → `[x]` |
| `agent-readiness/STATUS.md` | wiersz T32 → ready-for-commit |
| `agent-readiness/tasks/T32/*` | nowe — LOG, COMMIT, komunikat, runs |
| `docs/recipes/create-vault.md` | nowy — recepta |
| `docs/README.md` | zmieniony — indeks i lista wyjątków |
| `docs/vaults.md` | zmieniony — doprecyzowana liczba kontroli przy receipt |
| `.gitignore` | zmieniony — `!docs/recipes/`, `!docs/recipes/*.md` |

## Pliki w `git status`, które NIE należą do tego commita

- zmiany T25–T31. `.gitignore`, `docs/README.md` i `docs/vaults.md` są wspólne
  z wcześniejszymi zadaniami serii.

## Komendy dla hosta

```bash
cd ~/repos/ipor-fusion
git add agent-readiness/PLAN.md agent-readiness/STATUS.md agent-readiness/tasks/T32/
git add docs/recipes/create-vault.md docs/README.md docs/vaults.md .gitignore
git status --short
git commit -F agent-readiness/tasks/T32/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T32 na `committed <hash>`.

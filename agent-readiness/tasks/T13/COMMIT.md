# T13 — commit do wykonania ręcznie na hoście

## Komunikat

```
test(catalog): T13 classify factory pilot suites

Add config/test-suites.json with the seven factory pilot suites, its JSON schema,
a dependency-free validator behind npm run validate:test-suites, scoped
instructions in test/AGENTS.md and the first version of docs/testing.md.

Each entry records the provider variable name, pinned block, profile, actual FFI
use, fixture type and what setUp() deploys and mutates. Everything else under
test/ stays explicitly unclassified.

Both fork suites are classified as fork-fresh-deployment: they deploy their own
factory and bases and only read the mainnet proxy for configuration, so no suite
in the repository currently proves that a deployed factory is usable.

Verified with 129 local tests, 10 fork tests at block 23831825, and eight bad
catalog entries that each fail validation with a named cause.
```

Ten sam tekst jest w `agent-readiness/tasks/T13/commit-message.txt`.

## Pliki należące do tego commita

| Plik                                               | Zmiana                                                           |
| -------------------------------------------------- | ---------------------------------------------------------------- |
| `config/test-suites.json`                          | nowy — katalog 7 suit pilotażu fabryki                           |
| `config/test-suites.schema.json`                   | nowy — schemat katalogu                                          |
| `tools/validate-test-suites.mjs`                   | nowy — walidator bez zależności                                  |
| `package.json`                                     | zmieniony — skrypt `validate:test-suites`                        |
| `test/AGENTS.md`                                   | nowy — instrukcje scoped dla `test/`                             |
| `docs/testing.md`                                  | nowy — dobór testów, typy fixture'ów, providery, czytanie awarii |
| `docs/README.md`                                   | zmieniony — wpis w indeksie i w bloku `.gitignore`               |
| `.gitignore`                                       | zmieniony — `!docs/testing.md`                                   |
| `agent-readiness/PLAN.md`                          | checkbox T13 → `[x]`                                             |
| `agent-readiness/STATUS.md`                        | T12 → committed `4771509`; T13 → ready-for-commit                |
| `agent-readiness/tasks/T13/LOG.md`                 | nowy — przebieg i wyniki weryfikacji                             |
| `agent-readiness/tasks/T13/COMMIT.md`              | nowy — ta instrukcja                                             |
| `agent-readiness/tasks/T13/commit-message.txt`     | nowy — gotowy komunikat commita                                  |
| `agent-readiness/tasks/T13/runs.txt`               | nowy — wyjścia przebiegów zaliczających                          |
| `agent-readiness/tasks/T13/validator-negative.txt` | nowy — 8 przypadków negatywnych walidatora                       |

## Pliki w `git status`, które NIE należą do tego commita

Brak — drzewo było czyste po commicie T12 (`4771509`).

## Komendy dla hosta

```bash
cd /Users/piotrrzonsowski/repos/ipor-fusion
git add config/test-suites.json
git add config/test-suites.schema.json
git add tools/validate-test-suites.mjs
git add package.json
git add test/AGENTS.md
git add docs/testing.md
git add docs/README.md
git add .gitignore
git add agent-readiness/PLAN.md
git add agent-readiness/STATUS.md
git add agent-readiness/tasks/T13/LOG.md
git add agent-readiness/tasks/T13/COMMIT.md
git add agent-readiness/tasks/T13/commit-message.txt
git add agent-readiness/tasks/T13/runs.txt
git add agent-readiness/tasks/T13/validator-negative.txt
git status --short          # sprawdź, że staged są tylko pliki z tabeli
git commit -F agent-readiness/tasks/T13/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T13 na `committed <hash>` (albo zrobi to
następny agent w kroku 0 skilla).

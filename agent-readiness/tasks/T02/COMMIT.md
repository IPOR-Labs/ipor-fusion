# T02 — commit do wykonania ręcznie na hoście

## Komunikat

```
docs(setup): T02 add RPC environment template

Add an empty template for the five RPC provider variables used by the test
suite. Document how to create the ignored local .env file and why fork tests
need providers with historical archive state.

Verified that the names match every vm.envString use, all values are empty,
the README link and copy command work, and the edited Markdown is prettier-clean.
```

Ten sam tekst jest w `agent-readiness/tasks/T02/commit-message.txt`.

## Pliki należące do tego commita

| Plik                                           | Zmiana                                                      |
| ---------------------------------------------- | ----------------------------------------------------------- |
| `.env.example`                                 | nowy — pięć pustych zmiennych providerów RPC                |
| `README.md`                                    | zmieniony — instrukcja kopiowania i wymaganie archive state |
| `agent-readiness/PLAN.md`                      | checkbox T02 → `[x]`                                        |
| `agent-readiness/STATUS.md`                    | T01 → committed `87d86d8`; T02 → ready-for-commit           |
| `agent-readiness/tasks/T02/LOG.md`             | nowy — przebieg i wyniki weryfikacji                        |
| `agent-readiness/tasks/T02/COMMIT.md`          | nowy — instrukcja commita                                   |
| `agent-readiness/tasks/T02/commit-message.txt` | nowy — gotowy komunikat commita                             |

## Pliki w `git status`, które NIE należą do tego commita

Brak — drzewo było czyste przed rozpoczęciem T02.

## Komendy dla hosta

```bash
cd /Users/piotrrzonsowski/repos/ipor-fusion
git add .env.example
git add README.md
git add agent-readiness/PLAN.md
git add agent-readiness/STATUS.md
git add agent-readiness/tasks/T02/LOG.md
git add agent-readiness/tasks/T02/COMMIT.md
git add agent-readiness/tasks/T02/commit-message.txt
git status --short          # sprawdź, że staged są tylko pliki z tabeli
git commit -F agent-readiness/tasks/T02/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T02 na `committed <hash>` (albo zrobi to
następny agent w kroku 0 skilla).

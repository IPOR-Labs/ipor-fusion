# T03 — commit do wykonania ręcznie na hoście

## Komunikat

```
build(deps): T03 use reproducible dependency installation

Use npm ci locally and in CI so package-lock.json controls the installed Node
dependency tree. Document recursive initialization of the Git-pinned submodules
and how to recover a checkout with missing submodule contents.

Verified a clean npm ci without lockfile changes and initialized every recursive
submodule at its recorded commit in a fresh writable clone.
```

Ten sam tekst jest w `agent-readiness/tasks/T03/commit-message.txt`.

## Pliki należące do tego commita

| Plik                                           | Zmiana                                                      |
| ---------------------------------------------- | ----------------------------------------------------------- |
| `README.md`                                    | zmieniony — instalacja przez przypięte submoduły i `npm ci` |
| `.github/workflows/smart-contracts-build.yml`  | zmieniony — krok Install używa `npm ci`                     |
| `agent-readiness/PLAN.md`                      | checkbox T03 → `[x]`                                        |
| `agent-readiness/STATUS.md`                    | T02 → committed `6f0d8c8`; T03 → ready-for-commit           |
| `agent-readiness/tasks/T03/LOG.md`             | nowy — przebieg i wyniki weryfikacji                        |
| `agent-readiness/tasks/T03/COMMIT.md`          | nowy — instrukcja commita                                   |
| `agent-readiness/tasks/T03/commit-message.txt` | nowy — gotowy komunikat commita                             |

## Pliki w `git status`, które NIE należą do tego commita

Brak — drzewo było czyste przed rozpoczęciem T03.

## Komendy dla hosta

```bash
cd /Users/piotrrzonsowski/repos/ipor-fusion
git add README.md
git add .github/workflows/smart-contracts-build.yml
git add agent-readiness/PLAN.md
git add agent-readiness/STATUS.md
git add agent-readiness/tasks/T03/LOG.md
git add agent-readiness/tasks/T03/COMMIT.md
git add agent-readiness/tasks/T03/commit-message.txt
git status --short          # sprawdź, że staged są tylko pliki z tabeli
git commit -F agent-readiness/tasks/T03/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T03 na `committed <hash>` (albo zrobi to
następny agent w kroku 0 skilla).

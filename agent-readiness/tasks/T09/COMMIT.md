# T09 — commit do wykonania ręcznie na hoście

## Komunikat

```
docs(architecture): T09 map vault execution and storage

Add a current PlasmaVault architecture map covering clone and delegatecall
boundaries, direct and fallback entry points, namespaced storage, external
managers, and verified deposit, execute, and fallback call traces.

Link the map from the repository instructions and documentation index, and
mark the older vault overview's removed ERC4626 view component as historical.
```

Ten sam tekst jest w `agent-readiness/tasks/T09/commit-message.txt`.

## Pliki należące do tego commita

| Plik                                           | Zmiana                                            |
| ---------------------------------------------- | ------------------------------------------------- |
| `.gitignore`                                   | wyjątek dla `docs/architecture.md`                |
| `AGENTS.md`                                    | link do bieżącej mapy architektury                |
| `docs/README.md`                               | wpis w indeksie dokumentacji                      |
| `docs/architecture.md`                         | nowa mapa wykonania, storage i managerów          |
| `contracts/vaults/README.md`                   | ostrzeżenie o historycznym opisie ERC-4626        |
| `agent-readiness/PLAN.md`                      | checkbox T09 → `[x]`                              |
| `agent-readiness/STATUS.md`                    | T08 → committed `f3b624f`; T09 → ready-for-commit |
| `agent-readiness/tasks/T09/LOG.md`             | przebieg i wyniki weryfikacji                     |
| `agent-readiness/tasks/T09/COMMIT.md`          | instrukcja commita                                |
| `agent-readiness/tasks/T09/commit-message.txt` | gotowy komunikat commita                          |

## Pliki w `git status`, które NIE należą do tego commita

Brak — drzewo było czyste przed rozpoczęciem T09.

## Komendy dla hosta

```bash
cd /Users/piotrrzonsowski/repos/ipor-fusion
git add .gitignore
git add AGENTS.md
git add docs/README.md
git add docs/architecture.md
git add contracts/vaults/README.md
git add agent-readiness/PLAN.md
git add agent-readiness/STATUS.md
git add agent-readiness/tasks/T09/LOG.md
git add agent-readiness/tasks/T09/COMMIT.md
git add agent-readiness/tasks/T09/commit-message.txt
git status --short          # sprawdź, że staged są tylko pliki z tabeli
git commit -F agent-readiness/tasks/T09/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T09 na `committed <hash>` (albo zrobi
to następny agent w kroku 0).

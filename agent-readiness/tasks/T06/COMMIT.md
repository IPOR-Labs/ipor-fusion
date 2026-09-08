# T06 — commit do wykonania ręcznie na hoście

## Komunikat

```
build(format): T06 align pre-commit formatter versions

Align the pre-commit hook with the Prettier and Solidity plugin versions
already pinned in package.json. Keep the hook harness and formatting scope
unchanged.

Verified the local formatter and isolated pre-commit hook produce identical
output from the same unformatted Solidity sample.
```

Ten sam tekst jest w `agent-readiness/tasks/T06/commit-message.txt`.

## Pliki należące do tego commita

| Plik                                           | Zmiana                                              |
| ---------------------------------------------- | --------------------------------------------------- |
| `.pre-commit-config.yaml`                      | zmieniony — wersje Prettiera i pluginu zgodne z npm |
| `agent-readiness/PLAN.md`                      | checkbox T06 → `[x]`                                |
| `agent-readiness/STATUS.md`                    | T05 → committed `024509c`; T06 → ready-for-commit   |
| `agent-readiness/tasks/T06/LOG.md`             | nowy — przebieg i wyniki weryfikacji                |
| `agent-readiness/tasks/T06/COMMIT.md`          | nowy — instrukcja commita                           |
| `agent-readiness/tasks/T06/commit-message.txt` | nowy — gotowy komunikat commita                     |

## Pliki w `git status`, które NIE należą do tego commita

Brak — drzewo było czyste przed rozpoczęciem T06, a tymczasowe fixtures zostały usunięte.

## Komendy dla hosta

```bash
cd /Users/piotrrzonsowski/repos/ipor-fusion
git add .pre-commit-config.yaml
git add agent-readiness/PLAN.md
git add agent-readiness/STATUS.md
git add agent-readiness/tasks/T06/LOG.md
git add agent-readiness/tasks/T06/COMMIT.md
git add agent-readiness/tasks/T06/commit-message.txt
git status --short          # sprawdź, że staged są tylko pliki z tabeli
git commit -F agent-readiness/tasks/T06/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T06 na `committed <hash>` (albo zrobi to
następny agent w kroku 0 skilla).

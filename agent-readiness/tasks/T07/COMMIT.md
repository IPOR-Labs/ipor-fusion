# T07 — commit do wykonania ręcznie na hoście

## Komunikat

```
build(scripts): T07 fix the stale coverage command

Remove the coverage:file npm script because its tools/check_coverage.sh target
does not exist anywhere in the repository. Keep the remaining scripts and
lockfile unchanged instead of introducing a replacement coverage system.

Verified the stale command previously failed with exit 127 and no active
references to the missing script remain.
```

Ten sam tekst jest w `agent-readiness/tasks/T07/commit-message.txt`.

## Pliki należące do tego commita

| Plik                                           | Zmiana                                             |
| ---------------------------------------------- | -------------------------------------------------- |
| `package.json`                                 | zmieniony — usunięty martwy skrypt `coverage:file` |
| `agent-readiness/PLAN.md`                      | checkbox T07 → `[x]`                               |
| `agent-readiness/STATUS.md`                    | T06 → committed `f1a3be2`; T07 → ready-for-commit  |
| `agent-readiness/tasks/T07/LOG.md`             | nowy — przebieg i wyniki weryfikacji               |
| `agent-readiness/tasks/T07/COMMIT.md`          | nowy — instrukcja commita                          |
| `agent-readiness/tasks/T07/commit-message.txt` | nowy — gotowy komunikat commita                    |

## Pliki w `git status`, które NIE należą do tego commita

Brak — drzewo było czyste przed rozpoczęciem T07.

## Komendy dla hosta

```bash
cd /Users/piotrrzonsowski/repos/ipor-fusion
git add package.json
git add agent-readiness/PLAN.md
git add agent-readiness/STATUS.md
git add agent-readiness/tasks/T07/LOG.md
git add agent-readiness/tasks/T07/COMMIT.md
git add agent-readiness/tasks/T07/commit-message.txt
git status --short          # sprawdź, że staged są tylko pliki z tabeli
git commit -F agent-readiness/tasks/T07/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T07 na `committed <hash>` (albo zrobi to
następny agent w kroku 0 skilla).

# T05 — commit do wykonania ręcznie na hoście

## Komunikat

```
build(format): T05 add a non-mutating format check

Add a format:check npm script that checks Solidity contracts and tests with
the project's current Prettier configuration without rewriting files. Keep
the existing formatting commands as explicit, separate write operations.

Verified passing and failing fixtures preserve their hashes, and confirmed
the full check reports existing formatting drift without modifying sources.
```

Ten sam tekst jest w `agent-readiness/tasks/T05/commit-message.txt`.

## Pliki należące do tego commita

| Plik                                           | Zmiana                                                |
| ---------------------------------------------- | ----------------------------------------------------- |
| `package.json`                                 | zmieniony — nowy skrypt `format:check`                |
| `README.md`                                    | zmieniony — instrukcja kontroli i zapisu formatowania |
| `agent-readiness/PLAN.md`                      | checkbox T05 → `[x]`                                  |
| `agent-readiness/STATUS.md`                    | T04 → committed `7364631`; T05 → ready-for-commit     |
| `agent-readiness/tasks/T05/LOG.md`             | nowy — przebieg i wyniki weryfikacji                  |
| `agent-readiness/tasks/T05/COMMIT.md`          | nowy — instrukcja commita                             |
| `agent-readiness/tasks/T05/commit-message.txt` | nowy — gotowy komunikat commita                       |

## Pliki w `git status`, które NIE należą do tego commita

Brak — drzewo było czyste przed rozpoczęciem T05, a tymczasowe fixtures zostały usunięte.

## Komendy dla hosta

```bash
cd /Users/piotrrzonsowski/repos/ipor-fusion
git add package.json
git add README.md
git add agent-readiness/PLAN.md
git add agent-readiness/STATUS.md
git add agent-readiness/tasks/T05/LOG.md
git add agent-readiness/tasks/T05/COMMIT.md
git add agent-readiness/tasks/T05/commit-message.txt
git status --short          # sprawdź, że staged są tylko pliki z tabeli
git commit -F agent-readiness/tasks/T05/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T05 na `committed <hash>` (albo zrobi to
następny agent w kroku 0 skilla).

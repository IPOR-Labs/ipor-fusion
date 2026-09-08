# T08 — commit do wykonania ręcznie na hoście

## Komunikat

```
docs(agents): T08 add shared repository instructions

Add a root AGENTS.md with the repository map, verified setup and test commands,
Solidity safety rules, evidence boundaries, and change hygiene. Add a thin
tracked CLAUDE.md adapter and link the shared instructions from README.

Verified every local documentation link plus the documented local and Ethereum
fork factory test commands with 74 passing tests.
```

Ten sam tekst jest w `agent-readiness/tasks/T08/commit-message.txt`.

## Pliki należące do tego commita

| Plik                                           | Zmiana                                            |
| ---------------------------------------------- | ------------------------------------------------- |
| `AGENTS.md`                                    | nowy — kanoniczne instrukcje repo                 |
| `CLAUDE.md`                                    | nowy — cienki adapter do `AGENTS.md`              |
| `.gitignore`                                   | zmieniony — śledzenie wyłącznie root `CLAUDE.md`  |
| `README.md`                                    | zmieniony — link do instrukcji                    |
| `agent-readiness/PLAN.md`                      | checkbox T08 → `[x]`                              |
| `agent-readiness/STATUS.md`                    | T07 → committed `e9e5c0c`; T08 → ready-for-commit |
| `agent-readiness/tasks/T08/LOG.md`             | nowy — przebieg i wyniki weryfikacji              |
| `agent-readiness/tasks/T08/COMMIT.md`          | nowy — instrukcja commita                         |
| `agent-readiness/tasks/T08/commit-message.txt` | nowy — gotowy komunikat commita                   |

## Pliki w `git status`, które NIE należą do tego commita

Brak — drzewo było czyste przed rozpoczęciem T08.

## Komendy dla hosta

```bash
cd /Users/piotrrzonsowski/repos/ipor-fusion
git add AGENTS.md
git add CLAUDE.md
git add .gitignore
git add README.md
git add agent-readiness/PLAN.md
git add agent-readiness/STATUS.md
git add agent-readiness/tasks/T08/LOG.md
git add agent-readiness/tasks/T08/COMMIT.md
git add agent-readiness/tasks/T08/commit-message.txt
git status --short          # sprawdź, że staged są tylko pliki z tabeli
git commit -F agent-readiness/tasks/T08/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T08 na `committed <hash>` (albo zrobi to
następny agent w kroku 0 skilla).

# T10 — commit do wykonania ręcznie na hoście

## Komunikat

Pełny komunikat znajduje się w `agent-readiness/tasks/T10/commit-message.txt`.

## Pliki należące do tego commita

| Plik                                           | Zmiana                                            |
| ---------------------------------------------- | ------------------------------------------------- |
| `.gitignore`                                   | wyjątek dla `docs/roles-and-permissions.md`       |
| `docs/README.md`                               | wpis w indeksie dokumentacji                      |
| `docs/roles-and-permissions.md`                | mapa uprawnień, callerów i opóźnień               |
| `agent-readiness/PLAN.md`                      | checkbox T10 → `[x]`                              |
| `agent-readiness/STATUS.md`                    | T09 → committed `1ea8233`; T10 → ready-for-commit |
| `agent-readiness/tasks/T10/LOG.md`             | przebieg i wyniki weryfikacji                     |
| `agent-readiness/tasks/T10/COMMIT.md`          | instrukcja commita                                |
| `agent-readiness/tasks/T10/commit-message.txt` | gotowy komunikat commita                          |

## Pliki w `git status`, które NIE należą do tego commita

Brak — drzewo było czyste przed rozpoczęciem T10.

## Komendy dla hosta

```bash
cd /Users/piotrrzonsowski/repos/ipor-fusion
git add .gitignore
git add docs/README.md
git add docs/roles-and-permissions.md
git add agent-readiness/PLAN.md
git add agent-readiness/STATUS.md
git add agent-readiness/tasks/T10/LOG.md
git add agent-readiness/tasks/T10/COMMIT.md
git add agent-readiness/tasks/T10/commit-message.txt
git status --short          # sprawdź, że staged są tylko pliki z tabeli
git commit -F agent-readiness/tasks/T10/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T10 na `committed <hash>` (albo zrobi
to następny agent w kroku 0).

# T11 — commit do wykonania ręcznie na hoście

## Komunikat

Pełny komunikat znajduje się w `agent-readiness/tasks/T11/commit-message.txt`.

## Pliki należące do tego commita

| Plik                                           | Zmiana                                            |
| ---------------------------------------------- | ------------------------------------------------- |
| `.gitignore`                                   | wyjątek dla `docs/factories.md`                   |
| `contracts/factory/AGENTS.md`                  | instrukcje dla zmian w factory                    |
| `docs/README.md`                               | wpis w indeksie dokumentacji                      |
| `docs/factories.md`                            | wybór factory, wersji i trybu testu               |
| `agent-readiness/PLAN.md`                      | checkbox T11 → `[x]`                              |
| `agent-readiness/STATUS.md`                    | T10 → committed `4433979`; T11 → ready-for-commit |
| `agent-readiness/tasks/T11/LOG.md`             | przebieg i wyniki weryfikacji                     |
| `agent-readiness/tasks/T11/COMMIT.md`          | instrukcja commita                                |
| `agent-readiness/tasks/T11/commit-message.txt` | gotowy komunikat commita                          |

## Pliki w `git status`, które NIE należą do tego commita

Brak — drzewo było czyste przed rozpoczęciem T11.

## Komendy dla hosta

```bash
cd /Users/piotrrzonsowski/repos/ipor-fusion
git add .gitignore
git add contracts/factory/AGENTS.md
git add docs/README.md
git add docs/factories.md
git add agent-readiness/PLAN.md
git add agent-readiness/STATUS.md
git add agent-readiness/tasks/T11/LOG.md
git add agent-readiness/tasks/T11/COMMIT.md
git add agent-readiness/tasks/T11/commit-message.txt
git status --short          # sprawdź, że staged są tylko pliki z tabeli
git commit -F agent-readiness/tasks/T11/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T11 na `committed <hash>` (albo zrobi
to następny agent w kroku 0).

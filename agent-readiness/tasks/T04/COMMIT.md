# T04 — commit do wykonania ręcznie na hoście

## Komunikat

```
build(foundry): T04 pin the validated toolchain

Pin Foundry v1.7.1 in the local setup instructions and CI so agent and
automation runs do not drift with the stable release channel. Keep the
installer action pinned independently and leave compiler settings unchanged.

Verified forge build and all 66 local FusionFactory tests with the pinned
toolchain.
```

Ten sam tekst jest w `agent-readiness/tasks/T04/commit-message.txt`.

## Pliki należące do tego commita

| Plik                                           | Zmiana                                            |
| ---------------------------------------------- | ------------------------------------------------- |
| `README.md`                                    | zmieniony — lokalna instalacja Foundry `v1.7.1`   |
| `.github/workflows/smart-contracts-build.yml`  | zmieniony — CI instaluje Foundry `v1.7.1`         |
| `agent-readiness/PLAN.md`                      | checkbox T04 → `[x]`                              |
| `agent-readiness/STATUS.md`                    | T03 → committed `89f30eb`; T04 → ready-for-commit |
| `agent-readiness/tasks/T04/LOG.md`             | nowy — przebieg i wyniki weryfikacji              |
| `agent-readiness/tasks/T04/COMMIT.md`          | nowy — instrukcja commita                         |
| `agent-readiness/tasks/T04/commit-message.txt` | nowy — gotowy komunikat commita                   |

## Pliki w `git status`, które NIE należą do tego commita

Brak — drzewo było czyste przed rozpoczęciem T04.

## Komendy dla hosta

```bash
cd /Users/piotrrzonsowski/repos/ipor-fusion
git add README.md
git add .github/workflows/smart-contracts-build.yml
git add agent-readiness/PLAN.md
git add agent-readiness/STATUS.md
git add agent-readiness/tasks/T04/LOG.md
git add agent-readiness/tasks/T04/COMMIT.md
git add agent-readiness/tasks/T04/commit-message.txt
git status --short          # sprawdź, że staged są tylko pliki z tabeli
git commit -F agent-readiness/tasks/T04/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T04 na `committed <hash>` (albo zrobi to
następny agent w kroku 0 skilla).

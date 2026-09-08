# T01 — commit do wykonania ręcznie na hoście

## Komunikat

```
docs(agents): T01 track curated project documentation

Replace the blanket docs/ ignore with docs/* plus an explicit allow list, so a
curated document can be committed while local notes stay private. The only entry
today is !docs/README.md - a new documentation index that states what is tracked
here, how to add the next document (file plus its own exception line in the same
commit), the content rules (English, no secrets, no invented addresses or ABIs),
and where the documentation that already exists in the repo lives.

Verified: git check-ignore reports docs/README.md as not ignored while
docs/superpowers/, docs/scratch.md and .env stay ignored; git status offers
exactly .gitignore and docs/README.md; all six relative links resolve and the
git ls-files command quoted in the index returns 24 files. The file is
prettier-clean, because the pre-commit hook covers docs/README.md.
```

Ten sam tekst jest w `agent-readiness/tasks/T01/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `.gitignore` | zmieniony — `docs/` → sekcja `### Documentation ###`: `docs/*` + `!docs/README.md` |
| `docs/README.md` | nowy — indeks dokumentacji repo (angielski) |
| `agent-readiness/PLAN.md` | checkbox T01 → `[x]` |
| `agent-readiness/STATUS.md` | wiersz T01 → `ready-for-commit`; wiersz T00 uzupełniony o hash `7d64650` i decyzję o odroczeniu |
| `agent-readiness/tasks/T01/LOG.md` | nowy |
| `agent-readiness/tasks/T01/COMMIT.md` | nowy |
| `agent-readiness/tasks/T01/commit-message.txt` | nowy |

## Pliki w `git status`, które NIE należą do tego commita

brak — drzewo było czyste przed zadaniem.

## Komendy dla hosta

```bash
cd /Users/piotrrzonsowski/repos/ipor-fusion
git add .gitignore
git add docs/README.md
git add agent-readiness/PLAN.md
git add agent-readiness/STATUS.md
git add agent-readiness/tasks/T01/LOG.md
git add agent-readiness/tasks/T01/COMMIT.md
git add agent-readiness/tasks/T01/commit-message.txt
git status --short          # sprawdź, że staged są tylko pliki z tabeli
git commit -F agent-readiness/tasks/T01/commit-message.txt
```

Uwaga: hook `pre-commit` (prettier) obejmuje `docs/README.md` — plik jest już
sformatowany Prettierem, więc hook nie powinien go zmienić. `.gitignore` jest w `exclude`.

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T01 na `committed <hash>` (albo zrobi to
następny agent w kroku 0 skilla).

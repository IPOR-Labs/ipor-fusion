# T37 — commit do wykonania ręcznie na hoście

## Komunikat

```
docs(testing): T37 map pilot invariants to evidence

Add docs/invariants.md: the accounting, fee, withdrawal and permission
properties the pilot path relies on, each labelled tested or postulated, with the
test that proves it and the tolerance that test accepts.

Twelve properties are tested, eleven are postulated; the four gaps that matter
most for an agent working from this repository are listed as separate tasks, not
hidden as footnotes.
```

Ten sam tekst jest w `agent-readiness/tasks/T37/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/PLAN.md` | checkbox T37 → `[x]` |
| `agent-readiness/STATUS.md` | wiersz T37 → ready-for-commit |
| `agent-readiness/tasks/T37/*` | nowe — LOG, COMMIT, komunikat, runs |
| `docs/invariants.md` | nowy — mapa niezmienników |
| `docs/README.md` | zmieniony — indeks i lista wyjątków |
| `.gitignore` | zmieniony — `!docs/invariants.md` |

## Pliki w `git status`, które NIE należą do tego commita

- zmiany T25–T36. `.gitignore` i `docs/README.md` są wspólne z wcześniejszymi
  zadaniami serii.

## Komendy dla hosta

```bash
cd ~/repos/ipor-fusion
git add agent-readiness/PLAN.md agent-readiness/STATUS.md agent-readiness/tasks/T37/
git add docs/invariants.md docs/README.md .gitignore
git status --short
git commit -F agent-readiness/tasks/T37/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T37 na `committed <hash>`.

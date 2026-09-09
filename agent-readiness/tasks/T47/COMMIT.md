# T47 — commit do wykonania ręcznie na hoście

## Komunikat

```
docs(release): T47 assign deployment documentation ownership

Extend CODEOWNERS so that deployments/, abi/, catalog/, config/, docs/, tools/
and .github/ require review from the repository's existing owners, and add
docs/release.md: a ten-step checklist for changing what the repository claims
about a deployment, each step naming the command that produces its evidence.

The checklist is the path already walked for the Ethereum pilot, with a table
linking each step to the artifact it produced, plus the rules for keeping history
when a proxy is upgraded.

It states plainly that the scheduled drift job does not replace review.
```

Ten sam tekst jest w `agent-readiness/tasks/T47/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/PLAN.md` | checkbox T47 → `[x]` |
| `agent-readiness/STATUS.md` | wiersz T47 → ready-for-commit |
| `agent-readiness/tasks/T47/*` | nowe — LOG, COMMIT, komunikat, runs |
| `CODEOWNERS` | zmieniony — reguły dla katalogów operacyjnych |
| `docs/release.md` | nowy — checklista wydania rejestru |
| `docs/README.md` | zmieniony — indeks i lista wyjątków |
| `.gitignore` | zmieniony — `!docs/release.md` |

## Pliki w `git status`, które NIE należą do tego commita

- zmiany T25–T46. `.gitignore` i `docs/README.md` są wspólne z wcześniejszymi
  zadaniami serii.

## Komendy dla hosta

```bash
cd ~/repos/ipor-fusion
git add agent-readiness/PLAN.md agent-readiness/STATUS.md agent-readiness/tasks/T47/
git add CODEOWNERS docs/release.md docs/README.md .gitignore
git status --short
git commit -F agent-readiness/tasks/T47/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T47 na `committed <hash>`.

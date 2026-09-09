# T43 — commit do wykonania ręcznie na hoście

## Komunikat

```
ci(agents): T43 run secret-free pull request checks

Add .github/workflows/pr-checks.yml: a pull_request-triggered job with
contents: read and no secrets that builds, lints, runs the local contract suites
without RPC, validates every schema, manifest and generated catalog, and runs the
tooling tests that need no provider.

The pre-existing formatting baseline (301 files) is reported, not gated and not
reformatted here. Slack notifications and RPC fork tests stay in the privileged
pull_request_target workflow, which never shares its secrets with this job.

docs/ci.md documents the split and states plainly that the protection rules of
the external GitHub environment cannot be verified from this repository and must
be confirmed by whoever administers it.
```

Ten sam tekst jest w `agent-readiness/tasks/T43/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/PLAN.md` | checkbox T43 → `[x]` |
| `agent-readiness/STATUS.md` | wiersz T43 → ready-for-commit |
| `agent-readiness/tasks/T43/*` | nowe — LOG, COMMIT, komunikat, runs |
| `.github/workflows/pr-checks.yml` | nowy — job bez sekretów |
| `docs/ci.md` | nowy — opis podziału i baseline'u |
| `docs/README.md` | zmieniony — indeks i lista wyjątków |
| `.gitignore` | zmieniony — `!docs/ci.md` |

## Pliki w `git status`, które NIE należą do tego commita

- zmiany T25–T42. `.gitignore` i `docs/README.md` są wspólne z wcześniejszymi
  zadaniami serii.

## Komendy dla hosta

```bash
cd ~/repos/ipor-fusion
git add agent-readiness/PLAN.md agent-readiness/STATUS.md agent-readiness/tasks/T43/
git add .github/workflows/pr-checks.yml docs/ci.md docs/README.md .gitignore
git status --short
git commit -F agent-readiness/tasks/T43/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T43 na `committed <hash>`.

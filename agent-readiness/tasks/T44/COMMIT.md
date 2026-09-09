# T44 — commit do wykonania ręcznie na hoście

## Komunikat

```
ci(factory): T44 add trusted pilot fork checks

Add .github/workflows/pilot-fork-checks.yml, a workflow_call-only job that
receives exactly one secret, checks the provider and archive state first so that
infrastructure failures are reported as such, runs the deployed-usage suites on a
pinned block, compares factory:inspect against the manifest and uploads the
report as an artifact.

ci.yml calls it behind the existing authorize gate and includes its result in the
Slack report, leaving every other check in place.

Adding a second Ethereum suite in T36 had broken agent:doctor --rpc, which
required exactly one state probe per chain; it now checks every catalogued probe
and names the ones that fail.
```

Ten sam tekst jest w `agent-readiness/tasks/T44/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/PLAN.md` | checkbox T44 → `[x]` |
| `agent-readiness/STATUS.md` | wiersz T44 → ready-for-commit |
| `agent-readiness/tasks/T44/*` | nowe — LOG, COMMIT, komunikat, runs |
| `.github/workflows/pilot-fork-checks.yml` | nowy — zaufany job forkowy |
| `.github/workflows/ci.yml` | zmieniony — wywołanie jobu za `authorize` i wynik w raporcie |
| `tools/agent-doctor.mjs` | zmieniony — wiele probe'ów na sieć |
| `docs/ci.md` | zmieniony — opis zaufanego jobu |

## Pliki w `git status`, które NIE należą do tego commita

- zmiany T25–T43. `docs/ci.md` pochodzi z T43.

## Komendy dla hosta

```bash
cd ~/repos/ipor-fusion
git add agent-readiness/PLAN.md agent-readiness/STATUS.md agent-readiness/tasks/T44/
git add .github/workflows/pilot-fork-checks.yml .github/workflows/ci.yml tools/agent-doctor.mjs docs/ci.md
git status --short
git commit -F agent-readiness/tasks/T44/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T44 na `committed <hash>`.

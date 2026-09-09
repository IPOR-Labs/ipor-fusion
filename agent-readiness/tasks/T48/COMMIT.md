# T48 — commit do wykonania ręcznie na hoście

## Komunikat

```
test(agents): T48 measure readiness against the baseline

Add a machine-readable record for a run of the eight-task suite
(evals/agent-readiness/results.schema.json) and evals:report, which validates
records and reports success rate, human interventions, token cost, time to the
first relevant test and evidence quality.

Blocked tasks name their missing prerequisite and stay out of the success rate,
hard fails are surfaced per task, and two runs whose conditions differ in
anything but the commit are reported as not comparable — a score that moved with
the model or the memory mode says nothing about this repository.

No run is recorded yet; the measurement remains the open part of T00 and the
reporter says so. Verified with 10 tests.
```

Ten sam tekst jest w `agent-readiness/tasks/T48/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/PLAN.md` | checkbox T48 → `[x]` |
| `agent-readiness/STATUS.md` | wiersz T48 → ready-for-commit |
| `agent-readiness/tasks/T48/*` | nowe — LOG, COMMIT, komunikat, runs |
| `evals/agent-readiness/results.schema.json` | nowy — schemat rekordu przebiegu |
| `evals/agent-readiness/baseline.md` | zmieniony — sekcja „Recording a run as data" |
| `tools/evals-report.mjs` | nowy — `evals:report` |
| `tools/test-evals-report.mjs` | nowy — 10 testów |
| `.github/workflows/pr-checks.yml` | zmieniony — `evals:report:test` |
| `package.json` | zmieniony — dwa skrypty npm |

## Pliki w `git status`, które NIE należą do tego commita

- zmiany T25–T47. `.github/workflows/pr-checks.yml` i `package.json` są wspólne
  z wcześniejszymi zadaniami serii.

## Komendy dla hosta

```bash
cd ~/repos/ipor-fusion
git add agent-readiness/PLAN.md agent-readiness/STATUS.md agent-readiness/tasks/T48/
git add evals/agent-readiness/results.schema.json evals/agent-readiness/baseline.md
git add tools/evals-report.mjs tools/test-evals-report.mjs .github/workflows/pr-checks.yml package.json
git status --short
git commit -F agent-readiness/tasks/T48/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T48 na `committed <hash>`.

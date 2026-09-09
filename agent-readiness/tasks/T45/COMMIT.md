# T45 — commit do wykonania ręcznie na hoście

## Komunikat

```
ci(docs): T45 validate documentation and generated metadata

Add validate:docs, which resolves every relative link and heading anchor in the
documentation this repository ships and counts external links without fetching
any of them, so the check works offline.

Wire it into the secret-free pull request job next to the manifest, schema and
catalog validation, so that a broken link, a missing ABI and a catalog that no
longer matches its sources each fail the job.

Private notes ignored under docs/ stay out of scope, and per-task readiness logs
are excluded because they quote paths as prose. Verified with 7 tests.
```

Ten sam tekst jest w `agent-readiness/tasks/T45/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/PLAN.md` | checkbox T45 → `[x]` |
| `agent-readiness/STATUS.md` | wiersz T45 → ready-for-commit |
| `agent-readiness/tasks/T45/*` | nowe — LOG, COMMIT, komunikat, runs |
| `tools/validate-docs.mjs` | nowy — walidator odnośników |
| `tools/test-validate-docs.mjs` | nowy — 7 testów |
| `.github/workflows/pr-checks.yml` | zmieniony — `validate:docs` i `validate:docs:test` |
| `docs/ci.md` | zmieniony — opis kontroli dokumentacji |
| `package.json` | zmieniony — dwa skrypty npm |

## Pliki w `git status`, które NIE należą do tego commita

- zmiany T25–T44. `.github/workflows/pr-checks.yml`, `docs/ci.md` i
  `package.json` są wspólne z wcześniejszymi zadaniami serii.

## Komendy dla hosta

```bash
cd ~/repos/ipor-fusion
git add agent-readiness/PLAN.md agent-readiness/STATUS.md agent-readiness/tasks/T45/
git add tools/validate-docs.mjs tools/test-validate-docs.mjs .github/workflows/pr-checks.yml docs/ci.md package.json
git status --short
git commit -F agent-readiness/tasks/T45/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T45 na `committed <hash>`.

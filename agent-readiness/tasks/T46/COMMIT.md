# T46 — commit do wykonania ręcznie na hoście

## Komunikat

```
ci(deployments): T46 detect pilot factory drift

Add deployments:drift, which compares the verified pilot deployment against a
finalized block: the implementation behind the proxy, both runtime code hashes,
the reported version, and every component the verification report named — that
the factory still uses it and that its code is unchanged.

Unchanged, drift and an unusable comparison are three distinct exit codes, and
the scheduled workflow turns the last two into different CI errors, because an
upgrade and a dead provider call for different actions.

The report is uploaded as an artifact. Nothing here promotes a version, rewrites
a manifest or re-pins the blocks historical fixtures use. Verified with 6 tests.
```

Ten sam tekst jest w `agent-readiness/tasks/T46/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/PLAN.md` | checkbox T46 → `[x]` |
| `agent-readiness/STATUS.md` | wiersz T46 → ready-for-commit |
| `agent-readiness/tasks/T46/*` | nowe — LOG, COMMIT, komunikat, runs |
| `tools/detect-drift.mjs` | nowy — `deployments:drift` |
| `tools/test-detect-drift.mjs` | nowy — 6 testów |
| `.github/workflows/pilot-drift.yml` | nowy — harmonogram i artefakt |
| `docs/ci.md` | zmieniony — sekcja o drifcie |
| `package.json` | zmieniony — dwa skrypty npm |

## Pliki w `git status`, które NIE należą do tego commita

- zmiany T25–T45. `docs/ci.md` i `package.json` są wspólne z wcześniejszymi
  zadaniami serii.

## Komendy dla hosta

```bash
cd ~/repos/ipor-fusion
git add agent-readiness/PLAN.md agent-readiness/STATUS.md agent-readiness/tasks/T46/
git add tools/detect-drift.mjs tools/test-detect-drift.mjs .github/workflows/pilot-drift.yml docs/ci.md package.json
git status --short
git commit -F agent-readiness/tasks/T46/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T46 na `committed <hash>`.

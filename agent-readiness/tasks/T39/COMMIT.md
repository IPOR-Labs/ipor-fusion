# T39 — commit do wykonania ręcznie na hoście

## Komunikat

```
feat(execution): T39 revalidate plans before execution

Add vault:preflight, which checks a prepared plan against the chain as it is now
— chain, registry status, input hash, implementation, factory version, component
addresses, the caller's shape and the fee package resolved for that caller — and
then re-simulates the plan at the state it just read.

Any of those changing is a stop with the failing check named; a go states what
was read, and the report keeps the residual risk that the factory cannot enforce
implementation, version or fees atomically at execution time.

Verified against the pinned Ethereum block with 4 tests, including eight
tampered plans that each stop on exactly their own check.
```

Ten sam tekst jest w `agent-readiness/tasks/T39/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/PLAN.md` | checkbox T39 → `[x]` |
| `agent-readiness/STATUS.md` | wiersz T39 → ready-for-commit |
| `agent-readiness/tasks/T39/*` | nowe — LOG, COMMIT, komunikat, runs |
| `tools/preflight-plan.mjs` | nowy — `vault:preflight` |
| `tools/test-preflight-plan.mjs` | nowy — 4 testy |
| `docs/vaults.md` | zmieniony — sekcja o preflight |
| `package.json` | zmieniony — `vault:preflight`, `vault:preflight:test` |

## Pliki w `git status`, które NIE należą do tego commita

- zmiany T25–T38. `docs/vaults.md` i `package.json` są wspólne z wcześniejszymi
  zadaniami serii.

## Komendy dla hosta

```bash
cd ~/repos/ipor-fusion
git add agent-readiness/PLAN.md agent-readiness/STATUS.md agent-readiness/tasks/T39/
git add tools/preflight-plan.mjs tools/test-preflight-plan.mjs docs/vaults.md package.json
git status --short
git commit -F agent-readiness/tasks/T39/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T39 na `committed <hash>`.

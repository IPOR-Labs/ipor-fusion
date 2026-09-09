# T40 — commit do wykonania ręcznie na hoście

## Komunikat

```
feat(execution): T40 persist transaction state and recovery

Add vault:journal, a durable record of prepared, pending, unknown, confirmed and
reverted sends, each carrying the plan's hash, the deployment, the sender, a
hash of the calldata, the sender's nonce and the state history.

Preparing a second send for the same plan and sender while one is unresolved is
refused with DUPLICATE_IN_FLIGHT, and syncing an entry whose answer was lost
compares the sender's nonce and searches recent blocks for that transaction
instead of assuming an outcome.

Verified on a fork: a lost response is resolved to the transaction that was
actually mined, a reverted send stays reverted, and no path in the tool sends
anything.
```

Ten sam tekst jest w `agent-readiness/tasks/T40/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/PLAN.md` | checkbox T40 → `[x]` |
| `agent-readiness/STATUS.md` | wiersz T40 → ready-for-commit |
| `agent-readiness/tasks/T40/*` | nowe — LOG, COMMIT, komunikat, runs |
| `tools/execution-journal.mjs` | nowy — `vault:journal` |
| `tools/test-execution-journal.mjs` | nowy — 3 testy |
| `docs/vaults.md` | zmieniony — sekcja o dzienniku |
| `.gitignore` | zmieniony — `.fusion/` |
| `package.json` | zmieniony — `vault:journal`, `vault:journal:test` |

## Pliki w `git status`, które NIE należą do tego commita

- zmiany T25–T39. `.gitignore`, `docs/vaults.md` i `package.json` są wspólne z
  wcześniejszymi zadaniami serii.

## Komendy dla hosta

```bash
cd ~/repos/ipor-fusion
git add agent-readiness/PLAN.md agent-readiness/STATUS.md agent-readiness/tasks/T40/
git add tools/execution-journal.mjs tools/test-execution-journal.mjs docs/vaults.md .gitignore package.json
git status --short
git commit -F agent-readiness/tasks/T40/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T40 na `committed <hash>`.

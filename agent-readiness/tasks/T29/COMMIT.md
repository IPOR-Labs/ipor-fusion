# T29 — commit do wykonania ręcznie na hoście

## Komunikat

```
feat(vault): T29 simulate creation plans on a fork

Add vault:simulate, which runs exactly the plan's calldata on an ephemeral anvil
fork at a pinned block as the caller the plan names, then reports success or
revert, gas, the fork block and hash, and the SHA-256 of the plan it ran.

Created addresses are reported only when the call's return value and the
factory's own creation event agree; a caller with code, a plan for another
implementation and a missing provider are named refusals.

Nothing is broadcast and the fork is never repaired: no upgrade, no code
replacement, no role grant. Verified with 7 tests, including a real fork run and
a reverting creation reported as reverted.
```

Ten sam tekst jest w `agent-readiness/tasks/T29/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/PLAN.md` | checkbox T29 → `[x]` |
| `agent-readiness/STATUS.md` | wiersz T29 → ready-for-commit |
| `agent-readiness/tasks/T29/*` | nowe — LOG, COMMIT, komunikat, runs |
| `tools/simulate-vault.mjs` | nowy — `vault:simulate` |
| `tools/lib/fork.mjs` | nowy — cykl życia efemerycznego forka |
| `tools/test-simulate-vault.mjs` | nowy — 7 testów |
| `docs/vaults.md` | zmieniony — sekcja „Simulating the plan" |
| `package.json` | zmieniony — `vault:simulate`, `vault:simulate:test` |

## Pliki w `git status`, które NIE należą do tego commita

- zmiany T25–T28 (patrz ich COMMIT.md). `docs/vaults.md` i `package.json` są
  wspólne dla T27–T29, a `PLAN.md`/`STATUS.md` dla całej serii.

## Komendy dla hosta

```bash
cd ~/repos/ipor-fusion
git add agent-readiness/PLAN.md agent-readiness/STATUS.md agent-readiness/tasks/T29/
git add tools/simulate-vault.mjs tools/lib/fork.mjs tools/test-simulate-vault.mjs
git add docs/vaults.md package.json
git status --short
git commit -F agent-readiness/tasks/T29/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T29 na `committed <hash>`.

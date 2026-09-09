# T30 — commit do wykonania ręcznie na hoście

## Komunikat

```
feat(vault): T30 verify created vault state

Add a shared verifier for a created vault: component code, wiring between the
vault, its access, price, rewards, withdraw and fee managers, the owner's role
and execution delay, the redemption delay, underlying and vault decimals, and
the DAO fee package with its recipient and fee accounts.

Reading and checking are separate, so the 29 rules run offline against readings
captured from a real creation; vault:simulate now runs them after every
successful creation and reports status unverified when any of them fails.

Verified with 21 rule tests, including one that leaves every address existing
but unwired, plus the fork simulation test.
```

Ten sam tekst jest w `agent-readiness/tasks/T30/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/PLAN.md` | checkbox T30 → `[x]` |
| `agent-readiness/STATUS.md` | wiersz T30 → ready-for-commit |
| `agent-readiness/tasks/T30/*` | nowe — LOG, COMMIT, komunikat, runs |
| `tools/lib/vault-state.mjs` | nowy — odczyt i reguły stanu vaulta |
| `tools/test-vault-state.mjs` | nowy — 21 testów reguł |
| `test/fixtures/vault-state/created-vault.json` | nowy — realne odczyty z forka |
| `tools/simulate-vault.mjs` | zmieniony — weryfikacja po utworzeniu, status `unverified` |
| `tools/test-simulate-vault.mjs` | zmieniony — asercja `verification.ok` |
| `docs/vaults.md` | zmieniony — sekcja „Verifying the created vault" |
| `package.json` | zmieniony — `vault:state:test` |

## Pliki w `git status`, które NIE należą do tego commita

- zmiany T25–T29. `docs/vaults.md`, `package.json`, `tools/simulate-vault.mjs`
  i `tools/test-simulate-vault.mjs` są wspólne z wcześniejszymi zadaniami serii.

## Komendy dla hosta

```bash
cd ~/repos/ipor-fusion
git add agent-readiness/PLAN.md agent-readiness/STATUS.md agent-readiness/tasks/T30/
git add tools/lib/vault-state.mjs tools/test-vault-state.mjs test/fixtures/vault-state/
git add tools/simulate-vault.mjs tools/test-simulate-vault.mjs docs/vaults.md package.json
git status --short
git commit -F agent-readiness/tasks/T30/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T30 na `committed <hash>`.

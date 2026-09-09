# T31 — commit do wykonania ręcznie na hoście

## Komunikat

```
feat(vault): T31 resolve creation results from receipts

Add vault:verify, which reads a creation transaction, filters the receipt's logs
by the registered factory as emitter, decodes the creation event and completes
the instance with state reads instead of a Solidity return value.

Success, an unverified state, a revert, a pending transaction and an
insufficiently confirmed one are five distinct statuses; an event with the right
signature from another contract is a named refusal, and the context manager stays
unresolved rather than guessed.

Verified on an anvil fork: a real creation resolves the actual addresses and
passes the 29 state checks, while revert, pending, low finality and an unknown
hash each report their own outcome.
```

Ten sam tekst jest w `agent-readiness/tasks/T31/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/PLAN.md` | checkbox T31 → `[x]` |
| `agent-readiness/STATUS.md` | wiersz T31 → ready-for-commit |
| `agent-readiness/tasks/T31/*` | nowe — LOG, COMMIT, komunikat, runs |
| `tools/verify-vault.mjs` | nowy — `vault:verify` |
| `tools/lib/creation-log.mjs` | nowy — wybór eventu po emitencie |
| `tools/test-verify-vault.mjs` | nowy — testy filtra, argumentów i scenariusza na forku |
| `tools/lib/vault-state.mjs` | zmieniony — tolerancja nierozwiązanych komponentów |
| `docs/vaults.md` | zmieniony — sekcja o receipt |
| `package.json` | zmieniony — `vault:verify`, `vault:verify:test` |

## Pliki w `git status`, które NIE należą do tego commita

- zmiany T25–T30. `tools/lib/vault-state.mjs`, `docs/vaults.md` i `package.json`
  są wspólne z wcześniejszymi zadaniami serii.

## Komendy dla hosta

```bash
cd ~/repos/ipor-fusion
git add agent-readiness/PLAN.md agent-readiness/STATUS.md agent-readiness/tasks/T31/
git add tools/verify-vault.mjs tools/lib/creation-log.mjs tools/test-verify-vault.mjs
git add tools/lib/vault-state.mjs docs/vaults.md package.json
git status --short
git commit -F agent-readiness/tasks/T31/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T31 na `committed <hash>`.

# T41 — commit do wykonania ręcznie na hoście

## Komunikat

```
feat(execution): T41 execute validated plans through an EOA signer

Add vault:execute: it checks the plan against an explicit scope file, runs the
preflight, records the intent and the sender's nonce in the journal, sends the
plan's calldata verbatim with cast, and settles the entry from the chain.

Signing stays outside the repository: the key lives in a Foundry keystore account
named on the command line, while --private-key, --mnemonic and --interactive are
rejected outright because process arguments are readable by other users.

Verified on a fork with 4 tests: an out-of-scope target, selector, sender or
chain is refused without a journal entry, a stopped preflight sends nothing, and
an approved plan settles as confirmed with no key material anywhere in the output.
```

Ten sam tekst jest w `agent-readiness/tasks/T41/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/PLAN.md` | checkbox T41 → `[x]` |
| `agent-readiness/STATUS.md` | wiersz T41 → ready-for-commit |
| `agent-readiness/tasks/T41/*` | nowe — LOG, COMMIT, komunikat, runs |
| `tools/execute-plan.mjs` | nowy — `vault:execute` |
| `tools/test-execute-plan.mjs` | nowy — 4 testy |
| `config/execution/scope.example.json` | nowy — zakres wykonania |
| `docs/vaults.md` | zmieniony — sekcja o wykonaniu |
| `package.json` | zmieniony — `vault:execute`, `vault:execute:test` |

## Pliki w `git status`, które NIE należą do tego commita

- zmiany T25–T40. `docs/vaults.md` i `package.json` są wspólne z wcześniejszymi
  zadaniami serii.

## Komendy dla hosta

```bash
cd ~/repos/ipor-fusion
git add agent-readiness/PLAN.md agent-readiness/STATUS.md agent-readiness/tasks/T41/
git add tools/execute-plan.mjs tools/test-execute-plan.mjs config/execution/ docs/vaults.md package.json
git status --short
git commit -F agent-readiness/tasks/T41/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T41 na `committed <hash>`.

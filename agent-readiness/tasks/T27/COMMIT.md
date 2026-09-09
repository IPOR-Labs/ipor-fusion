# T27 — commit do wykonania ręcznie na hoście

## Komunikat

```
feat(vault): T27 validate vault creation configuration

Add config/vaults/vault-creation.schema.json with a worked example and
validate:vault-config, which checks the input against the schema and against the
deployment manifest it names, without reading any RPC.

Units live in the field names (*Seconds, *Bps, decimals), the fee package must
be stated in full including its recipient, and only a variant the deployment
lists as supported is accepted; docs/vaults.md documents the input.

Verified with 17 validator tests covering the example plus wrong units, an
incomplete fee package, a zero recipient, unsupported and unknown variants, an
unknown deployment and an unknown property.
```

Ten sam tekst jest w `agent-readiness/tasks/T27/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/PLAN.md` | checkbox T27 → `[x]` |
| `agent-readiness/STATUS.md` | wiersz T27 → ready-for-commit |
| `agent-readiness/tasks/T27/LOG.md` | nowy |
| `agent-readiness/tasks/T27/COMMIT.md` | nowy |
| `agent-readiness/tasks/T27/commit-message.txt` | nowy |
| `agent-readiness/tasks/T27/runs.txt` | nowy |
| `config/vaults/vault-creation.schema.json` | nowy — schemat wejścia |
| `config/vaults/example.json` | nowy — poprawny przykład |
| `tools/validate-vault-config.mjs` | nowy — walidator (CLI) |
| `tools/lib/vault-config.mjs` | nowy — wczytanie i reguły wejścia |
| `tools/test-validate-vault-config.mjs` | nowy — 17 testów |
| `tools/lib/json-schema.mjs` | nowy — wspólny walker schematu |
| `docs/vaults.md` | nowy — opis wejścia |
| `docs/README.md` | zmieniony — indeks i lista wyjątków |
| `.gitignore` | zmieniony — `!docs/vaults.md` |
| `package.json` | zmieniony — dwa skrypty npm |

## Pliki w `git status`, które NIE należą do tego commita

- zmiany T25 (`config/test-suites.json`, `docs/testing.md`, `test/AGENTS.md`,
  `test/deployed-factories/`) i T26 (`deployments/`, `docs/deployments.md`).
- **Uwaga:** `.gitignore` zawiera zmiany T26 i T27, a `agent-readiness/PLAN.md`
  i `agent-readiness/STATUS.md` — wszystkich zadań serii. Commituj serię w
  kolejności T25 → T26 → T27 albo jednym commitem.

## Komendy dla hosta

```bash
cd ~/repos/ipor-fusion
git add agent-readiness/PLAN.md agent-readiness/STATUS.md agent-readiness/tasks/T27/
git add config/vaults/ tools/validate-vault-config.mjs tools/test-validate-vault-config.mjs
git add tools/lib/json-schema.mjs tools/lib/vault-config.mjs docs/vaults.md docs/README.md .gitignore package.json
git status --short          # sprawdź, że staged są tylko pliki z tabeli
git commit -F agent-readiness/tasks/T27/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T27 na `committed <hash>`.

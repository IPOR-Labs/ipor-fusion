# T28 — commit do wykonania ręcznie na hoście

## Komunikat

```
feat(vault): T28 build a verifiable creation plan

Add vault:plan, which turns a validated input and one historical block into a
plan artifact: target, caller, zero value, calldata with its decoded arguments,
the implementation and factory version read at that block, the fee package the
factory resolves for that caller, the block hash and the input's SHA-256.

Planning refuses an unverified manifest entry, an implementation or version
other than the recorded one, and any difference between the resolved fee package
and the expected one; nothing is signed or broadcast.

Verified with 14 planner tests against a local fake provider, including a
calldata round trip through cast decode-calldata, plus 18 config tests.
```

Ten sam tekst jest w `agent-readiness/tasks/T28/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/PLAN.md` | checkbox T28 → `[x]` |
| `agent-readiness/STATUS.md` | wiersz T28 → ready-for-commit |
| `agent-readiness/tasks/T28/*` | nowe — LOG, COMMIT, komunikat, runs |
| `tools/plan-vault.mjs` | nowy — `vault:plan` |
| `tools/test-plan-vault.mjs` | nowy — 14 testów |
| `tools/lib/chain.mjs` | nowy — wspólny dostęp read-only do łańcucha |
| `tools/lib/vault-config.mjs` | zmieniony — override `FUSION_DEPLOYMENTS_DIR` |
| `tools/test-validate-vault-config.mjs` | zmieniony — test wpisu `candidate` |
| `docs/vaults.md` | zmieniony — sekcja „Planning one creation" |
| `package.json` | zmieniony — `vault:plan`, `vault:plan:test` |

## Pliki w `git status`, które NIE należą do tego commita

- zmiany T25, T26 i T27 (patrz ich COMMIT.md).
- **Uwaga:** `docs/vaults.md`, `tools/lib/vault-config.mjs`,
  `tools/test-validate-vault-config.mjs` i `package.json` powstały w T27 i są
  tu zmieniane dalej; `PLAN.md`/`STATUS.md` zbierają całą serię. Commituj serię
  w kolejności T25 → T26 → T27 → T28 albo jednym commitem.

## Komendy dla hosta

```bash
cd ~/repos/ipor-fusion
git add agent-readiness/PLAN.md agent-readiness/STATUS.md agent-readiness/tasks/T28/
git add tools/plan-vault.mjs tools/test-plan-vault.mjs tools/lib/chain.mjs
git add tools/lib/vault-config.mjs tools/test-validate-vault-config.mjs docs/vaults.md package.json
git status --short
git commit -F agent-readiness/tasks/T28/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T28 na `committed <hash>`.

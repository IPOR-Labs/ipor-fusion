# T42 — commit do wykonania ręcznie na hoście

## Komunikat

```
feat(execution): T42 export and simulate Safe creation plans

Add vault:safe, which resolves the factory's fee package for the Safe's own
address, refuses a plan whose caller is not a contract, exports the call as a
Safe Transaction Builder batch carrying the plan's calldata verbatim, and
simulates the Safe as the factory's direct caller on a fork.

--compare-with resolves the same index for another address, typically the owner
EOA, and names every field that differs: the package list, both rates and the
recipient.

Nothing is proposed or published to a Safe service and no wrapper contract is
involved; the simulation impersonates the Safe address and does not run its
threshold logic. Verified with 5 tests.
```

Ten sam tekst jest w `agent-readiness/tasks/T42/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/PLAN.md` | checkbox T42 → `[x]` |
| `agent-readiness/STATUS.md` | wiersz T42 → ready-for-commit |
| `agent-readiness/tasks/T42/*` | nowe — LOG, COMMIT, komunikat, runs |
| `tools/export-safe-plan.mjs` | nowy — `vault:safe` |
| `tools/lib/safe-plan.mjs` | nowy — pakiet i porównanie opłat |
| `tools/test-export-safe-plan.mjs` | nowy — 5 testów |
| `docs/vaults.md` | zmieniony — sekcja o Safe |
| `package.json` | zmieniony — `vault:safe`, `vault:safe:test` |

## Pliki w `git status`, które NIE należą do tego commita

- zmiany T25–T41. `docs/vaults.md` i `package.json` są wspólne z wcześniejszymi
  zadaniami serii.

## Komendy dla hosta

```bash
cd ~/repos/ipor-fusion
git add agent-readiness/PLAN.md agent-readiness/STATUS.md agent-readiness/tasks/T42/
git add tools/export-safe-plan.mjs tools/lib/safe-plan.mjs tools/test-export-safe-plan.mjs
git add docs/vaults.md package.json
git status --short
git commit -F agent-readiness/tasks/T42/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T42 na `committed <hash>`.

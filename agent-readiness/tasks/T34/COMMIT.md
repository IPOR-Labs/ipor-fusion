# T34 — commit do wykonania ręcznie na hoście

## Komunikat

```
feat(catalog): T34 generate pilot fuse interface metadata

Add catalog:generate, which rewrites only interface.generated in
catalog/fuses.json from the Solidity sources: struct names, tuple signatures and
selectors, the file:line of every struct and field, the market constant's
file:line and the SHA-256 of both fuse sources.

catalog:check fails when the catalog no longer matches the sources, and
validate:catalog now compares the described fields and signatures against the
generated ones.

Verified with 6 tests: regeneration is byte-identical, a changed struct changes
the output and is caught, editorial content survives regeneration, and a renamed
struct fails by name.
```

Ten sam tekst jest w `agent-readiness/tasks/T34/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/PLAN.md` | checkbox T34 → `[x]` |
| `agent-readiness/STATUS.md` | wiersz T34 → ready-for-commit |
| `agent-readiness/tasks/T34/*` | nowe — LOG, COMMIT, komunikat, runs |
| `tools/generate-catalog.mjs` | nowy — generator |
| `tools/test-generate-catalog.mjs` | nowy — 6 testów |
| `tools/validate-catalog.mjs` | zmieniony — kontrola opis vs. wygenerowane |
| `catalog/fuses.json` | zmieniony — wypełnione `interface.generated` |
| `docs/fuse-catalog.md` | zmieniony — sekcja „Generated structure" |
| `package.json` | zmieniony — trzy skrypty npm |

## Pliki w `git status`, które NIE należą do tego commita

- zmiany T25–T33. `catalog/fuses.json`, `docs/fuse-catalog.md`,
  `tools/validate-catalog.mjs` i `package.json` są wspólne z T33.

## Komendy dla hosta

```bash
cd ~/repos/ipor-fusion
git add agent-readiness/PLAN.md agent-readiness/STATUS.md agent-readiness/tasks/T34/
git add tools/generate-catalog.mjs tools/test-generate-catalog.mjs tools/validate-catalog.mjs
git add catalog/fuses.json docs/fuse-catalog.md package.json
git status --short
git commit -F agent-readiness/tasks/T34/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T34 na `committed <hash>`.

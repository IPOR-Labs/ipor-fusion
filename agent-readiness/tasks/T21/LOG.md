# T21 — Schemat i walidator manifestów

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Codex
- **Baza:** `efd2691`, branch `feature/agents-support`
- **Zależności:** T20 (`efd2691`)

## Zakres wykonany

- `deployments/schema/factories.schema.json` definiuje manifest per chain:
  identity/status, proxy, provenance, code/compiler, ABI+SHA-256, dependencies
  i block-specific verification.
- `tools/validate-deployments.mjs` waliduje JSON Schema bez nowej zależności,
  zgodność chain ID z wpisem i katalogiem, unikalność ID, niezerowy adres,
  istnienie/hash ABI oraz referencje do raportu i testu.
- Produkcyjny manifest może wskazywać tylko `abi/`. Syntetyczne fixtures mają
  osobną dozwoloną ścieżkę i nie tworzą pozoru wdrożenia.
- Status `verified` wymaga kompletu: block number/hash, timestamp, inspector
  version, report i compatibility test. Samo wypełnienie pól nadal wymaga
  review dowodów.
- Domyślne `npm run validate:deployments` raportuje obecnie 0 produkcyjnych
  manifestów i waliduje jeden syntetyczny candidate.

## Weryfikacja

Wyniki są zapisane w `runs.txt`.

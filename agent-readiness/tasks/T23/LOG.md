# T23 — Manifest pierwszego kandydata

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Codex
- **Baza:** `4657eb6`, branch `feature/agents-support`
- **Zależności:** T21 (`1d28609`), T22 (`4657eb6`)

## Zakres wykonany

- Dodano jeden produkcyjny manifest
  `deployments/1/factories.json` z ID
  `ethereum-fusion-factory-cd05909c`.
- Wpis zachowuje `candidate` i wskazuje Ethereum chain 1, proxy, explorerowo
  powiązaną implementację, standardowy slot ERC-1967, źródło lookupu oraz
  ABI+SHA-256 z T22.
- Compiler dotyczy implementacji wdrożonej: Solidity 0.8.30, optimizer 200,
  Cancun. Nie skopiowano ustawień bieżącego checkoutu.
- Nieustalone deployment tx/block, runtime hashes, source commit,
  reportedVersion, dependencies i cały verification record pozostają jawnie
  `null`/puste.
- Jedyną zadeklarowaną obsługiwaną operacją jest zweryfikowana sygnatura
  `clone(string,string,address,uint256,address,uint256)`.

## Weryfikacja

Wyniki są zapisane w `runs.txt`.

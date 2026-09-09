# T22 — ABI jednej wdrożonej wersji

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Codex
- **Baza:** `1d28609`, branch `feature/agents-support`
- **Zależności:** T20 (`efd2691`), T21 (`1d28609`)

## Zakres wykonany

- `contract_source` dla proxy potwierdził `ERC1967Proxy` i explorerowe
  powiązanie z implementacją `0xf19c…63f5`.
- `contract_source` dla implementacji potwierdził `FusionFactory`, Solidity
  `0.8.30`, optimizer `200` runs i Cancun. Nie przypisano mu ustawień
  bieżącego checkoutu (`10000000` runs).
- `contract_abi` zwrócił 78 wpisów; zapisano je pod pełnym adresem
  implementacji wraz z SHA-256 i pochodzeniem narzędzia/SDK.
- Walidator ABI znajduje dokładnie jeden `clone`, wylicza selector przez
  `cast sig`, koduje sześć reprezentatywnych argumentów i dekoduje calldata do
  identycznych wartości.
- Adapter dla operacji `clone` nie jest potrzebny, bo wdrożone i bieżące ABI
  mają tę samą sygnaturę. Nie rozszerzono tego wniosku na zachowanie.

## Weryfikacja

Wyniki są zapisane w `runs.txt`.

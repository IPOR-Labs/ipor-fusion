# T18 — Opcjonalna diagnostyka RPC

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Codex
- **Baza:** `4660699`, branch `feature/agents-support`
- **Zależności:** T16 (`3f68cf7`), T17 (`4660699`)

## Zakres wykonany

- Dotychczasowy `agent:doctor` pozostaje offline; połączenie następuje wyłącznie
  przy `--rpc --chain <id> --block <number>`.
- Doctor wybiera nazwę providera i `stateProbe` z katalogu, sprawdza
  `eth_chainId`, a następnie `eth_getCode` pod wskazanym adresem i blokiem.
- Raport rozróżnia `RPC_UNAVAILABLE`, `CHAIN_MISMATCH`,
  `HISTORICAL_STATE_UNAVAILABLE` i brak konfiguracji katalogowej.
- URL, osadzony klucz, transportowy wyjątek i ciało błędu JSON-RPC nie trafiają
  do tekstu ani JSON.
- `stateProbe` jest częścią schematu katalogu: wymagany dla forków, zabroniony
  dla suit lokalnych. Sukces probe'a nie jest przedstawiany jako weryfikacja
  wdrożenia.

## Weryfikacja

Wyniki są zapisane w `runs.txt`.

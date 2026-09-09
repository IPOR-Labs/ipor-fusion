# T15 — Lokalny zestaw bez RPC

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Codex
- **Baza:** `212a6e6`, branch `feature/agents-support`
- **Zależności:** T13 (`2b3e415`), T14 (`212a6e6`)

## Zakres wykonany

- `npm run test:unit` waliduje `config/test-suites.json`, wybiera pięć wpisów
  `local-deployment` i uruchamia je grupami pod profilami zapisanymi w katalogu.
- Runner nadpisuje nazwy providerów występujące w katalogu nieosiągalnym adresem
  loopback tylko dla procesów Forge. Dzięki temu przypadkowe użycie RPC nie może
  skorzystać z lokalnego `.env` ani odziedziczonych credentials.
- Błędny katalog, pusta selekcja, brak Forge i niezerowy kod Forge są
  propagowane jako niezerowy wynik polecenia.
- Dokumentacja opisuje dokładne pokrycie: 129 testów pięciu lokalnych suit
  fabryk. Reszta repo pozostaje jawnie poza zakresem.
- Testy runnera używają tymczasowego fork-only katalogu i `/bin/false`, aby
  sprawdzić oba wymagane przypadki negatywne bez uruchamiania kontraktów.

## Weryfikacja

Wyniki są zapisane w `runs.txt`.

# T19 — Konserwatywny dobór testów do zmiany

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Codex
- **Baza:** `5f70266`, branch `feature/agents-support`
- **Zależności:** T13 (`2b3e415`), T15 (`b0bbd2a`), T16 (`3f68cf7`)

## Zakres wykonany

- `npm run test:affected -- --base <commit>` zbiera zmiany z `base...HEAD`
  oraz staged, unstaged i untracked worktree.
- Selekcja łączy jawne granice ryzyka z rekurencyjnym grafem relatywnych
  importów Solidity dla każdej sklasyfikowanej suity.
- Factory oraz wspólne storage/vault/access/oracle wybierają cały pilot.
  Nieznana ścieżka, helper lub niesklasyfikowany test także wybiera pełny
  katalog i jawnie podaje konserwatywny powód.
- Zmiana wyłącznie dokumentacji wybiera kontrole walidacyjne bez testów
  kontraktów. `--json` zwraca nieuruchamiający plan.
- Tryb domyślny deleguje do `test:unit` i `test:fork`. Brak RPC lub błąd
  któregokolwiek runnera kończy się niezerowym kodem.

## Weryfikacja

Wyniki są zapisane w `runs.txt`.

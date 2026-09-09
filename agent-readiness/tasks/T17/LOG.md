# T17 — Diagnostyka lokalnego środowiska

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Codex
- **Baza:** `3f68cf7`, branch `feature/agents-support`
- **Zależności:** T03 (`89f30eb`), T04 (`7364631`), T13 (`2b3e415`)

## Zakres wykonany

- `npm run agent:doctor` tworzy czytelny raport tekstowy, a wariant
  `-- --json` stabilny raport `schemaVersion: 1`.
- Diagnostyka jest offline i sprawdza: Node, npm, dokładny pin Foundry,
  `package.json`, top-level dependencies przez `npm ls`, wszystkie
  rekursywne submoduły oraz obecność nazw z `.env.example`.
- Różnica Node/npm jest ostrzeżeniem, aby nowsze działające środowisko nie
  blokowało diagnostyki; różnica Foundry jest błędem ze względu na pin repo.
- Błędy zależności i submodułów podają konkretne komendy naprawcze.
- Raport nie zawiera wartości zmiennych ani treści `.env`.

## Weryfikacja

Wyniki są zapisane w `runs.txt`.

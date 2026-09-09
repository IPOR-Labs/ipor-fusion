# T45 — Kontrola aktualności dokumentów i artefaktów

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 przez Claude Code
- **Baza:** `562fea3`, branch `feature/agents-support`
- **Zależności:** T21 (`1d28609`), T26, T34, T43 (ready-for-commit)

## Zakres wykonany

- `tools/validate-docs.mjs` (`validate:docs`) — rozwiązuje wszystkie względne
  odnośniki i kotwice nagłówków w dokumentacji, którą repo publikuje; linki
  zewnętrzne tylko liczy, nigdy nie pobiera; bloki kodu traktuje jak przykłady.
- `tools/test-validate-docs.mjs` — 7 testów.
- `.github/workflows/pr-checks.yml` — `validate:docs` obok walidacji manifestów,
  schematów i `catalog:check`, plus `validate:docs:test` w testach narzędzi.
- `docs/ci.md` — sekcja „What the documentation check covers".
- `package.json` — `validate:docs`, `validate:docs:test`.

## Kroki

1. **Zakres skanu** — pliki, które git śledzi lub śledziłby, ograniczone do `docs/`, `README.md`, każdego `AGENTS.md` i `evals/`. Ignorowane prywatne notatki są poza zakresem z definicji.
2. **Pierwszy przebieg** — wykrył `agent-readiness/tasks/T00/LOG.md` z cytatem `[tasks.json](tasks.json)`; to zapis procesu, nie dokumentacja, więc został wyłączony z zakresu, a commitowanego logu nie ruszano.
3. **Bez sieci** — linki `https://` są liczone; test używa `example.invalid`, żeby pobranie było niemożliwe.
4. **Testy i CI** — 7/7; kroki dopisane do jobu bez sekretów.

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| Job waliduje lokalne linki dokumentacji | `npm run validate:docs` w `pr-checks.yml`; 213 lokalnych linków | ✅ |
| …schematy i referencje manifestów | `validate:test-suites`, `validate:deployments`, `validate:pilot-abi`, `validate:vault-config`, `validate:catalog` w tym samym kroku | ✅ |
| …brak różnic po generacji katalogu | `npm run catalog:check` w tym samym kroku | ✅ |
| Bez zależności od zewnętrznych stron | linki zewnętrzne tylko liczone; test z `example.invalid` | ✅ |
| Celowo zerwany link powoduje błąd | test „a broken relative link fails" | ✅ |
| Brak ABI powoduje błąd | test „a link to a missing ABI or manifest fails" + `validate:deployments` sprawdzający ścieżkę i SHA-256 ABI | ✅ |
| Nieaktualny artefakt powoduje błąd | `catalog:check` → `OUT_OF_DATE` (dowód w testach T34) | ✅ |
| Prywatne, ignorowane dokumenty poza zakresem | skan bierze tylko pliki nieignorowane przez git | ✅ |

## Odstępstwa od planu

- Kontrola aktualności artefaktów nie powiela istniejących walidatorów — zadanie
  dokłada brakujący element (linki) i spina wszystko w jednym kroku CI.

## Follow-upy (poza zakresem, NIE zrobione)

- Sprawdzanie linków w `agent-readiness/tasks/**` wymagałoby najpierw poprawienia
  cytatów w commitowanych logach; to osobna, kosmetyczna zmiana.
- Kontrola linków zewnętrznych (istnienie stron) wymaga sieci i osobnego,
  nieblokującego joba.

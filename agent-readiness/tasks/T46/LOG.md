# T46 — Wykrywanie zmian jednego wdrożenia

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 przez Claude Code
- **Baza:** `562fea3`, branch `feature/agents-support`
- **Zależności:** T24 (`562fea3`), T26, T44 (ready-for-commit)

## Zakres wykonany

- `tools/detect-drift.mjs` (`deployments:drift`) — porównanie wdrożenia z jego
  potwierdzonym stanem na świeżym, sfinalizowanym bloku: implementacja, oba
  hashe runtime, wersja i wszystkie komponenty z raportu weryfikacji (użycie i
  hash kodu). Trzy różne kody wyjścia: 0 bez zmian, 1 drift, 2 porównanie
  niemożliwe.
- `tools/test-detect-drift.mjs` — 6 testów na syntetycznym stanie potwierdzonym.
- `.github/workflows/pilot-drift.yml` — harmonogram dzienny + `workflow_dispatch`,
  artefakt z raportem, osobne komunikaty błędu dla driftu i dla awarii.
- `docs/ci.md` — sekcja „The scheduled drift job".
- `package.json` — `deployments:drift`, `deployments:drift:test`.

## Kroki

1. **Źródło stanu potwierdzonego** — raport weryfikacji z T26 (`deployments/reports/…`), nie manifest: to on ma hashe komponentów.
2. **Świeży blok** — domyślnie tag `finalized`; przebieg realny: blok 25938401, brak różnic.
3. **Rozdzielenie wyników** — awaria providera, brak bloku i inna sieć kończą się kodem 2; różnica w kodzie/implementacji/wersji kodem 1.
4. **Testy** — syntetyczny rejestr i raport przez `FUSION_DEPLOYMENTS_DIR`; 6/6. Szczegóły w [`runs.txt`](runs.txt).

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| Cykliczny odczyt fabryki i jej zależności na świeżym bloku finalnym | `pilot-drift.yml` (cron dzienny) + `--block finalized` | ✅ |
| Raport różnic z ostatnim potwierdzonym stanem | lista `differences` z polem, wartością potwierdzoną i obserwowaną | ✅ |
| Zmiana implementacji i awaria RPC to różne wyniki | exit 1 vs exit 2; osobne adnotacje `::error` w workflow; testy dla obu | ✅ |
| Raport nie promuje automatycznie nowej wersji | narzędzie tylko czyta; ostrzeżenie w raporcie i w dokumentacji | ✅ |
| Nie zmienia historycznych fixture'ów | żaden plik nie jest zapisywany poza `--out`; przypięte bloki nietknięte | ✅ |
| Wynik publikowany jako artefakt/status CI | `upload-artifact` z `if: always()` i status joba | ✅ |

## Odstępstwa od planu

- Porównanie opłat nie wchodzi do driftu: pakiety opłat zmieniają się w normalnej
  eksploatacji i są sprawdzane dla konkretnego callera przy planowaniu (T28) oraz
  w preflight (T39). Drift pilnuje tożsamości kodu, nie polityki cenowej.

## Follow-upy (poza zakresem, NIE zrobione)

- Powiadomienie (Slack) o drifcie — dziś sygnałem jest status joba i artefakt.
- Objęcie driftem kolejnych wdrożeń, gdy pojawią się następne wpisy `verified`.

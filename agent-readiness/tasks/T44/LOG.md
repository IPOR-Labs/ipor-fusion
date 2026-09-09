# T44 — Osobny zaufany job testów forkowych

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 przez Claude Code
- **Baza:** `562fea3`, branch `feature/agents-support`
- **Zależności:** T16 (`3f68cf7`), T18 (`5f70266`), T25 (ready-for-commit), T43 (ready-for-commit)

## Zakres wykonany

- `.github/workflows/pilot-fork-checks.yml` — job wyłącznie `workflow_call`,
  jeden zadeklarowany sekret (`ETHEREUM_PROVIDER_URL`), kolejność: doctor RPC →
  suity `deployed-factory` na przypiętym bloku → porównanie `factory:inspect` z
  manifestem → artefakt z raportem. Blok jest wejściem z domyślną wartością.
- `.github/workflows/ci.yml` — nowy job `pilot-fork` za `authorize`, wynik wchodzi
  do raportu Slack; pozostałe kontrole bez zmian.
- `tools/agent-doctor.mjs` — obsługa wielu probe'ów na sieć (regresja po T36).
- `docs/ci.md` — sekcja „The trusted fork job" i uzupełniona lista rzeczy poza
  zakresem CI.

## Kroki

1. **Wykonanie wszystkich kroków lokalnie** — doctor, suity forkowe i porównanie z manifestem; wyniki w [`runs.txt`](runs.txt).
2. **Rozróżnienie awarii infrastruktury** — wymuszone dwa scenariusze: brak odpowiedzi providera (`RPC_UNAVAILABLE`) i brak stanu historycznego (`HISTORICAL_STATE_UNAVAILABLE`); job zamienia je na czytelny błąd CI z odnośnikiem do `docs/troubleshooting.md`.
3. **Naprawa regresji** — druga suita na chain 1 (z T36) wywracała `agent:doctor --rpc`; doctor sprawdza teraz każdy probe i wypisuje te, które zawiodły. `agent:doctor:test` 5/5.
4. **Składnia wyrażeń** — `needs['pilot-fork'].result`, bo identyfikator joba zawiera myślnik.

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| Job pilotażowy z RPC i jawnymi zasadami dostępu do sekretów | `workflow_call` only, jeden sekret, wywołanie za `authorize`, komentarz w nagłówku pliku | ✅ |
| Zachowane istniejące użyteczne kontrole | `ci.yml` zachowuje `build`, `notify` i `report`; nic nie usunięto | ✅ |
| Pozytywny przebieg na przypiętym bloku | doctor OK, 2 suity forkowe PASS, manifest zgodny | ✅ |
| Czytelny błąd infrastruktury | dwa wymuszone scenariusze + krok emitujący `::error title=RPC infrastructure` | ✅ |
| Nieznane ustawienia GitHub environments wskazane do sprawdzenia | `docs/ci.md`, sekcja o workflow uprzywilejowanym i lista „What is not covered here" | ✅ |
| Bez automatycznej zmiany uprawnień organizacji | żadna zmiana nie dotyka ustawień GitHub; workflow deklaruje tylko `contents: read` | ✅ |

## Odstępstwa od planu

- Naprawa `agent:doctor` wykracza poza literalny zakres zadania, ale bez niej
  pierwszy krok jobu nie przechodzi. Regresja powstała w T36 i jest opisana
  wprost.

## Follow-upy (poza zakresem, NIE zrobione)

- Uruchomienie workflow w GitHub Actions (brak poświadczeń w tym środowisku);
  pierwszy przebieg po commicie trzeba obejrzeć.
- Cykliczny odczyt na świeżym bloku (drift) — T46.

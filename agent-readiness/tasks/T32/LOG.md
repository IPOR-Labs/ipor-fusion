# T32 — Recepta utworzenia podstawowego vaulta

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 przez Claude Code
- **Baza:** `562fea3`, branch `feature/agents-support`
- **Zależności:** T26, T28, T29, T30, T31 (wszystkie ready-for-commit)

## Zakres wykonany

- `docs/recipes/create-vault.md` — pełna ścieżka: warunki wstępne i `agent:doctor`,
  inspekcja wdrożenia, napisanie i walidacja wejścia, plan z kontrolą calldata,
  symulacja z weryfikacją stanu, odtworzenie wyniku z receipt (z próbą na
  lokalnym forku) oraz jawna lista tego, czego recepta **nie** daje.
- `.gitignore` — wyjątki `!docs/recipes/` i `!docs/recipes/*.md`.
- `docs/README.md` — recepta w indeksie i na liście śledzonych plików.

## Kroki

1. **Przejście recepty** — wszystkie polecenia wykonane dosłownie, na zmienionym wejściu (inna nazwa, symbol i redemption delay), żeby nic nie „przeszło" przez zgodność z przykładem. Wyniki w [`runs.txt`](runs.txt).
2. **Kontrola linków** — każdy odnośnik w dokumencie wskazuje istniejący plik.
3. **Poprawka w `docs/vaults.md`** — liczba kontroli przy weryfikacji z receipt to 28, nie 29 (context manager jest nierozwiązywalny); zdanie doprecyzowane.

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| Recepta łączy inspect → plan → simulate → verify | pięć kroków dokumentu, każdy z istniejącym poleceniem npm | ✅ |
| Pokazuje wejście, rezultat i ograniczenia pilotażu | sekcja 2 (wejście), 4–5 (rezultat), „What this recipe does not give you" | ✅ |
| Przejście w świeżym środowisku daje zweryfikowany vault na forku | pełny przebieg: `success` + `verification.ok` w symulacji i `success` 28/28 w `vault:verify` na forku | ✅ |
| Bez dodatkowych ustaleń poza dokumentacją i parametrami użytkownika | użyto wyłącznie poleceń z dokumentu i własnych parametrów; jedyne wymagane dane to provider RPC opisany w kroku 0 | ✅ |

## Odstępstwa od planu

- Krok 5 opisuje próbę na lokalnym forku, bo realna transakcja jest poza
  zakresem repo. Recepta mówi to wprost.

## Follow-upy (poza zakresem, NIE zrobione)

- Recepta nie obejmuje konfiguracji strategii — to T35/T36.
- Krok „preflight przed wykonaniem" (T39) i dziennik transakcji (T40) będą
  wymagały dopisania do recepty, gdy powstaną.

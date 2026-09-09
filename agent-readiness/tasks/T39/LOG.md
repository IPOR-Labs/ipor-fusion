# T39 — Walidacja planu bezpośrednio przed wykonaniem

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 przez Claude Code
- **Baza:** `562fea3`, branch `feature/agents-support`
- **Zależności:** T28, T29, T30 (wszystkie ready-for-commit)

## Zakres wykonany

- `tools/preflight-plan.mjs` (`vault:preflight`) — 11 kontroli planu wobec
  bieżącego stanu (chain, status w rejestrze, hash wejścia, implementacja,
  wersja, komponenty, kształt callera, źródło i wartości pakietu opłat) oraz
  ponowna symulacja na właśnie odczytanym bloku. `--block`, `--max-age-blocks`,
  `--skip-simulation`, `--json`.
- `tools/test-preflight-plan.mjs` — 4 testy, w tym osiem podmienionych planów.
- `docs/vaults.md` — sekcja „Preflight: revalidating a plan before execution" z
  tabelą kontroli i akapitem o ryzyku, którego „go" nie usuwa.
- `package.json` — `vault:preflight`, `vault:preflight:test`.

## Kroki

1. **Kontrole wobec artefaktu** — plan niesie oczekiwaną implementację, wersję i pakiet opłat; preflight porównuje je z odczytem na bieżącym bloku, a komponenty z raportem weryfikacji z T26.
2. **Ponowna symulacja** — `vault:simulate` uruchamiany na bloku właśnie odczytanym (nie na bloku planu); wynik trafia do raportu jako `simulation.current`.
3. **Przebiegi** — pinned block i chain head; osiem scenariuszy odmowy. Szczegóły w [`runs.txt`](runs.txt).

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| Preflight sprawdza chain ID, implementację, komponenty, callera, opłaty i limity | 11 kontroli; „limity" pilotażu to indeks i zawartość pakietu opłat oraz status wpisu w rejestrze — vault jeszcze nie istnieje, więc limity rynków nie mają tu zastosowania | ✅ |
| Ponowna symulacja aktualnego stanu | `simulation.current` + test asercji bloku i `verification` | ✅ |
| Nadal bez signera | narzędzie tylko czyta i uruchamia symulację na forku | ✅ |
| Zmiana implementacji, odbiorcy/opłat lub zakresu unieważnia plan | osiem testów, każdy zatrzymuje się na własnej kontroli | ✅ |
| Opisane ryzyko zmiany stanu po symulacji | `residualRisk` w raporcie i akapit „The risk a »go« does not remove" w dokumentacji | ✅ |

## Odstępstwa od planu

- „Limity" z opisu zakresu odnoszą się do vaulta, którego w momencie tworzenia
  jeszcze nie ma. Preflight sprawdza więc limity **operacji**: status wdrożenia,
  wiek planu (`--max-age-blocks`) i indeks pakietu opłat. Limity rynków są
  sprawdzane po utworzeniu, przez `vault:configure` i weryfikator stanu.

## Follow-upy (poza zakresem, NIE zrobione)

- Preflight nie zapisuje swojego wyniku obok planu; powiązanie preflight →
  wysyłka → receipt to dziennik z T40.
- Ścieżka Safe (T42) potrzebuje własnych kontroli `caller.shape` i pakietu opłat
  dla adresu Safe.

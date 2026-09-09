# T34 — Generowanie strukturalnej części katalogu

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 przez Claude Code
- **Baza:** `562fea3`, branch `feature/agents-support`
- **Zależności:** T33 (ready-for-commit)

## Zakres wykonany

- `tools/generate-catalog.mjs` — `catalog:generate` i `catalog:check`; zapisuje
  wyłącznie poddrzewo `interface.generated`: struktury, sygnatury i selektory
  `enter`/`exit`, `plik:linia` struktur, pól i stałej rynku oraz SHA-256 obu
  źródeł fuse'ów.
- `tools/validate-catalog.mjs` — dodatkowa kontrola: opis redakcyjny (pola,
  sygnatura, selektor) musi zgadzać się z częścią wygenerowaną.
- `catalog/fuses.json` — wypełnione `interface.generated`.
- `tools/test-generate-catalog.mjs` — 6 testów.
- `docs/fuse-catalog.md` — sekcja „Generated structure".
- `package.json` — `catalog:generate`, `catalog:check`, `catalog:generate:test`.

## Kroki

1. **Parser struktur** — czyta deklarację struktury z pliku fuse'a, pomija komentarze, buduje krotkę typów i liczy selektor przez `cast sig`; nieparsowalna linia i brak struktury to nazwane błędy (exit 2).
2. **Generowanie** — `npm run catalog:generate` → `updated`; ponowne uruchomienie → `unchanged` i identyczne bajty.
3. **Kontrola w CI** — `npm run catalog:check` zwraca 1 z `OUT_OF_DATE`, gdy katalog rozjechał się ze źródłami.
4. **Testy** — `npm run catalog:generate:test` → 6/6; szczegóły w [`runs.txt`](runs.txt).

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| Generator struktur, selektorów i odnośników do źródeł | `interface.generated` z sygnaturami, selektorami i `plik:linia` dla struktur, pól i stałej rynku | ✅ |
| Ponowne generowanie jest deterministyczne | test „regenerating is deterministic": drugie uruchomienie daje `unchanged` i te same bajty | ✅ |
| Zmiana struktury Solidity zmienia wynik | test z dodanym polem `address recipient`: nowa sygnatura, nowy selektor, nowa lista pól | ✅ |
| Generator nie nadpisuje informacji redakcyjnych | test „editorial content is never overwritten": znaczenia pól, opis substrates, notatki, role, wycena i testy bez zmian | ✅ |
| Oddzielone zweryfikowane adresy | `deployments` nie są dotykane przez generator (asercja `deepEqual` w teście) | ✅ |

## Odstępstwa od planu

- Generator używa własnego parsera struktur zamiast `forge inspect`/`solc --ast`:
  potrzebne są numery linii i brak zależności od zbudowanych artefaktów. Parser
  celowo kończy się błędem `STRUCT_UNPARSEABLE` zamiast zgadywać przy składni,
  której nie rozumie.

## Follow-upy (poza zakresem, NIE zrobione)

- `catalog:check` powinien trafić do CI razem z pozostałymi walidacjami (T43/T45).
- Generator obsługuje struktury o polach prostych typów; zagnieżdżone struktury i
  tablice struktur wymagają rozszerzenia, gdy pojawi się taka integracja.

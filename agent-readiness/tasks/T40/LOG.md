# T40 — Dziennik transakcji i bezpieczne wznowienie

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 przez Claude Code
- **Baza:** `562fea3`, branch `feature/agents-support`
- **Zależności:** T31 (ready-for-commit), T39 (ready-for-commit)

## Zakres wykonany

- `tools/execution-journal.mjs` (`vault:journal`) — polecenia `record`, `sent`,
  `sync`, `list`; trwałe stany `prepared`, `pending`, `unknown`, `confirmed`,
  `reverted`; wpis niesie hash planu, wdrożenie, nadawcę, adres docelowy, hash
  calldata, **nonce**, hash transakcji i historię stanów.
- `tools/test-execution-journal.mjs` — 3 testy, w tym pełny scenariusz utraty
  odpowiedzi na forku.
- `docs/vaults.md` — sekcja „The execution journal" z tabelą stanów i dwiema
  regułami bezpieczeństwa.
- `.gitignore` — `.fusion/` (stan lokalny, nie do repozytorium).
- `package.json` — `vault:journal`, `vault:journal:test`.

## Kroki

1. **Model stanów** — `prepared → pending → confirmed|reverted`, z `unknown` jako jawnym stanem po utracie odpowiedzi; przejścia zapisywane w `history`.
2. **Blokada duplikatu** — `record` odmawia (`DUPLICATE_IN_FLIGHT`), dopóki istnieje nierozstrzygnięty wpis dla tego samego planu i nadawcy.
3. **Odzyskiwanie po timeout** — `sync` bez hasha porównuje nonce nadawcy; nieużyty nonce → „nic nie zostało wykopane" i brak decyzji; użyty nonce → wyszukanie transakcji o tym nonce w ostatnich blokach i rozstrzygnięcie z receipt.
4. **Testy** — `npm run vault:journal:test` → 3/3; przebieg w [`runs.txt`](runs.txt).

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| Trwałe stany prepared/pending/reverted/confirmed/unknown | pięć stanów, zapisywane w pliku wpisu wraz z historią | ✅ |
| Identyfikacja planu, hash transakcji i nonce | `plan.sha256`, `transaction.dataSha256`, `txHash`, `nonce` | ✅ |
| Odzyskiwanie po timeout | `sent --no-response` → `unknown`, `sync` znajduje transakcję po nonce | ✅ |
| Zasymulowana utrata odpowiedzi prowadzi do sprawdzenia poprzedniej transakcji | test krok 4–5: najpierw kontrola nonce, potem znalezienie i rozstrzygnięcie | ✅ |
| Nie powoduje automatycznego kolejnego utworzenia vaulta | `record` odmawia przy nierozstrzygniętym wpisie; żadna ścieżka narzędzia nie wysyła transakcji | ✅ |
| Bez integracji z produkcyjnym signerem | narzędzie tylko czyta łańcuch i zapisuje pliki | ✅ |

## Odstępstwa od planu

- `sync` przeszukuje ostatnie `--scan-blocks` bloków (domyślnie 50) w poszukiwaniu
  transakcji o zapisanym nonce. Dla starszych przypadków narzędzie mówi wprost,
  że nie znalazło, i odsyła do explorera — zamiast zgadywać.

## Follow-upy (poza zakresem, NIE zrobione)

- Powiązanie wpisu dziennika z raportem preflight (T39) i raportem `vault:verify`
  (T31) w jeden ślad; dziś dziennik tylko wypisuje polecenie `vault:verify`.
- Adapter podpisujący (T41) powinien tworzyć wpis przed wysyłką i aktualizować go
  natychmiast po niej.

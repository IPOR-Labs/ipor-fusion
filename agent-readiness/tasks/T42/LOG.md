# T42 — Eksport dla Safe i właściwa ścieżka callera

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 przez Claude Code
- **Baza:** `562fea3`, branch `feature/agents-support`
- **Zależności:** T10 (`4433979`), T28, T29, T39 (ready-for-commit)

## Zakres wykonany

- `tools/export-safe-plan.mjs` (`vault:safe`) — pakiet Safe Transaction Builder z
  calldata planu bez zmian, rozstrzygnięcie pakietu opłat dla adresu Safe,
  porównanie z innym callerem (`--compare-with`) i symulacja Safe jako
  bezpośredniego callera fabryki.
- `tools/lib/safe-plan.mjs` — czyste części: dokument pakietu i porównanie opłat.
- `tools/test-export-safe-plan.mjs` — 5 testów (dwa bez sieci).
- `docs/vaults.md` — sekcja „Creating through a Safe".
- `package.json` — `vault:safe`, `vault:safe:test`.

## Kroki

1. **Caller musi być kontraktem** — plan z callerem bez kodu jest odrzucany (`CALLER_NOT_A_CONTRACT`), żeby eksport nie podmienił po cichu tego, kogo widzi fabryka.
2. **Opłaty dla Safe** — czytane dla adresu Safe; niezgodność z planem to `FEE_PACKAGE_MISMATCH`.
3. **Porównanie z EOA** — `compareFeeResolution` wykrywa różnicę listy, obu stawek i odbiorcy; testy pokrywają każdy przypadek osobno i łącznie.
4. **Symulacja** — impersonacja adresu Safe na forku: `msg.sender` to Safe; wynik `success`, gas 8 874 000.
5. **Testy** — `npm run vault:safe:test` → 5/5; szczegóły w [`runs.txt`](runs.txt).

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| Eksport planu w formacie obsługiwanym przez Safe | plik Safe Transaction Builder 1.0 z jedną transakcją; `data` identyczne z planem (asercja w teście) | ✅ |
| Symulacja wywołania przez Safe jako bezpośredniego callera | impersonacja Safe na forku, `simulation.callerIsTheSafe: true` | ✅ |
| Pakiet opłat i role sprawdzane dla Safe | opłaty rozstrzygane dla adresu Safe i porównywane z planem; brak wymaganej roli dla `clone` (ścieżka permissionless) — wariant `supervised-clone` nie jest wspierany przez wpis w rejestrze | ✅ |
| Test wykrywa różnicę względem EOA właściciela | testy `compareFeeResolution`: inna lista, inne stawki, inny odbiorca — każdy wykryty; dla pilotażowego Safe różnicy nie ma i raport to mówi wprost | ✅ |
| Bez publikowania propozycji do zewnętrznej usługi | narzędzie zapisuje plik; nie ma żadnego wywołania sieciowego poza RPC i forkiem | ✅ |
| Nie wdrażać dodatkowego wrappera | brak jakiegokolwiek deploymentu; ostrzeżenie w raporcie tłumaczy, dlaczego wrapper zmieniłby `msg.sender` | ✅ |

## Odstępstwa od planu

- Symulacja nie wykonuje `execTransaction` Safe (progi, podpisy właścicieli).
  Odpowiada na pytanie, które zadaje fabryka — kto jest `msg.sender` — i mówi
  wprost, czego nie sprawdza.
- Różnica opłat Safe vs EOA nie występuje dla pilotażowego Safe (brak pakietów
  business-client), więc dowód poprawności wykrywania jest w testach czystej
  funkcji, a nie w danych z łańcucha.

## Follow-upy (poza zakresem, NIE zrobione)

- Symulacja pełnej ścieżki `execTransaction` z podpisami właścicieli Safe.
- Import pakietu do Safe UI i podpisanie to działanie człowieka; nie ma tu
  integracji z Safe Transaction Service i nie powinno być bez osobnej decyzji.

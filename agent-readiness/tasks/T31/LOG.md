# T31 — Odtworzenie wyniku z receipt

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 przez Claude Code
- **Baza:** `562fea3`, branch `feature/agents-support`
- **Zależności:** T30 (ready-for-commit)

## Zakres wykonany

`vault:verify` odtwarza wynik utworzenia z transakcji, bez polegania na wartości
zwracanej przez wywołanie Solidity.

- `tools/verify-vault.mjs` — `vault:verify --chain <id> --tx <hash> [--rpc-url <url>]
  [--min-confirmations <n>] [--config <plik>] [--json]`; pięć rozróżnionych
  statusów (`success`, `unverified`, `reverted`, `pending`, `not-final`) i nazwane
  odmowy.
- `tools/lib/creation-log.mjs` — czysty wybór eventu utworzenia z logów: filtr po
  emitencie, rozpoznanie obcego emitenta, braku i niejednoznaczności.
- `tools/lib/vault-state.mjs` — reguły tolerują nierozwiązane komponenty:
  brakujący adres trafia do `unresolved`, nigdy nie „przechodzi".
- `tools/test-verify-vault.mjs` — testy: czyste testy filtra emitenta, kontrola
  argumentów i pełny scenariusz na forku anvil.
- `docs/vaults.md` — sekcja „Resolving a real creation from its receipt".
- `package.json` — `vault:verify`, `vault:verify:test`.

## Kroki

1. **Rozwiązanie adresów** — event `FusionInstanceCreated` (index, wersja, nazwa, symbol, decimals, underlying, owner, vault, vault base, fee manager) uzupełniony odczytami vaulta: access manager, price manager, rewards manager.
2. **Withdraw manager** — wdrożona wersja nie ma gettera na vaulcie, więc szukany jest wśród emitentów logów tej transakcji przez `getPlasmaVaultAddress()`; test potwierdza, że został znaleziony.
3. **Context manager** — nierozwiązywalny publicznym interfejsem tej wersji; trafia do `result.unresolved`, nie jest zgadywany.
4. **Scenariusz na forku** — `npm run vault:verify:test` → sukces, `not-final`, `reverted`, `pending` i `TRANSACTION_UNKNOWN` w jednym przebiegu; szczegóły w [`runs.txt`](runs.txt).

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| Odczyt receipt i filtrowanie emitenta | `selectCreationLog` + testy: obcy emitent, brak, niejednoznaczność | ✅ |
| Dekodowanie eventów ABI właściwej wersji | sygnatura ze źródła repo, przyjęta po zgodności topicu (jak w T29); ABI wdrożenia nie zawiera tego eventu | ✅ |
| Uzupełnienie adresów odczytami stanu | access/price/rewards manager z vaulta, withdraw manager przez probe emitentów | ✅ |
| Transakcja testowa na forku zwraca rzeczywiste adresy | test na anvil: `plasmaVault`, owner i underlying zgodne z wejściem, 29 kontroli T30 przechodzi | ✅ |
| Revert, pending, brak finalności i obcy event rozróżnione | cztery osobne statusy + `FOREIGN_CREATION_EVENT` | ✅ |
| Nie polegać na return value z testu Solidity | narzędzie czyta wyłącznie receipt, logi i stan | ✅ |

## Odstępstwa od planu

- `--rpc-url` pozwala wskazać inny endpoint (np. lokalny fork). Bez tego testu
  „transakcja testowa na Anvil/forku" nie dałoby się wykonać. Wartość nigdy nie
  trafia do raportu — raportowane jest tylko `provider.source: "override"`.
- Domyślny próg finalności to 1 potwierdzenie; wymagana liczba dla sieci jest
  decyzją operacyjną i podaje się ją jawnie (`--min-confirmations`).

## Follow-upy (poza zakresem, NIE zrobione)

- Rozwiązanie context managera wymaga albo eventu z jego adresem, albo gettera w
  nowszej wersji fabryki — do sprawdzenia przy kolejnej wersji wdrożenia.
- Dziennik wykonania (T40) powinien łączyć plan, symulację i ten raport w jeden
  ślad transakcji.

# T33 — Katalog danych jednej integracji ERC4626

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 przez Claude Code
- **Baza:** `562fea3`, branch `feature/agents-support`
- **Zależności:** T12 (`4771509`), T20 (`efd2691`)

## Zakres wykonany

- `catalog/fuses.schema.json` — schemat katalogu integracji: rynek, źródła, ABI
  danych `enter`/`exit` ze znaczeniem pól, substrates, wycena, role, testy i
  wdrożenia z poziomem dowodu (`observed` / `unverified` / `absent`).
- `catalog/fuses.json` — jedna pozycja: `ethereum-erc4626-market-100001`.
- `tools/validate-catalog.mjs` (`validate:catalog`) — schemat plus kontrole wobec
  checkoutu: istnienie ścieżek, zgodność stałej rynku, selektory, arność struktur
  i reguły dowodowe dla wdrożeń.
- `tools/test-validate-catalog.mjs` — 13 testów.
- `docs/fuse-catalog.md` (+ `.gitignore`, indeks `docs/README.md`) — po co katalog
  jest, co znaczą poziomy dowodu i dwa nieoczywiste fakty pilotażu.
- `package.json` — `validate:catalog`, `validate:catalog:test`.

## Kroki

1. **Adresy z rejestru** — `fusion_address_lookup` (MCP) dla „Erc4626" na chain 1; wybrane `SupplyFuseErc4626Market1` i `BalanceFuseErc4626Market1`.
2. **Potwierdzenie on-chain** — `cast call ... MARKET_ID()`/`VERSION()` i `cast code` na bloku 25937526; wyniki w [`runs.txt`](runs.txt).
3. **Zgodność z kodem** — stała `ERC4626_0001`, selektory `enter`/`exit`, pola struktur i realny check substrate'u (`isSubstrateAsAssetGranted(MARKET_ID, data.vault)`).
4. **Walidacja** — `npm run validate:catalog` i 13 testów odrzuceń.

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| Schemat i jedna pozycja pilotażowa | `catalog/fuses.schema.json` + `catalog/fuses.json` | ✅ |
| Supply/balance fuse, market ID, substrates, ABI danych, oracle, role, testy, pochodzenie adresów | wszystkie grupy pól obecne i wymagane przez schemat | ✅ |
| Zgodność z kodem | walidator sprawdza stałą rynku, selektory, nazwy i arność struktur oraz istnienie ścieżek; 6 testów negatywnych na te reguły | ✅ |
| Zgodność z istniejącym rejestrem | adresy pochodzą z `fusion_address_lookup` i zostały odczytane on-chain (`MARKET_ID` = 100001) | ✅ |
| Pola niezweryfikowane nie udają wdrożonych i gotowych | `status`, `matchesCurrentSource: null/false`, `verifiedEntries: []`, `interface.generated: null`; walidator odrzuca `unverified` z danymi obserwacji i `matchesCurrentSource: true` bez obserwacji | ✅ |

## Odstępstwa od planu

- „Oracle" opisano jako źródło wyceny (`PriceOracleMiddlewareManager` z fallbackiem
  na `PriceOracleMiddleware`) i wycenianą wielkość, bez adresu price feedu: dla
  tej integracji feed zależy od konkretnego vaulta ERC4626 wskazanego jako
  substrate, a żaden nie jest jeszcze zweryfikowany (`verifiedEntries: []`).

## Follow-upy (poza zakresem, NIE zrobione)

- Komentarz w `Erc4626SupplyFuse.sol` mówi, że substrates to „assets", a kod
  sprawdza adres vaulta ERC4626. Poprawka komentarza to osobna zmiana w
  kontraktach.
- `interface.generated` czeka na generator z T34.
- Wdrożony balance fuse jest starszy niż źródło w repo; jeśli pilotaż strategii
  (T35) ma go używać, trzeba to jawnie potwierdzić albo użyć własnego wdrożenia.

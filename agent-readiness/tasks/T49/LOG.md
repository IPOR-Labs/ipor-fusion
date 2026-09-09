# T49 — Jedna fabryka price feedu

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 przez Claude Code
- **Baza:** `562fea3`, branch `feature/agents-support`
- **Zależności:** T21 (`1d28609`), T24 (`562fea3`), T32, T33 (ready-for-commit)

## Zakres wykonany

Jedna wskazana, istniejąca fabryka price feedu na sieci pilotażu: **ERC4626
Price Feed Factory** na Ethereum.

- `abi/erc4626-price-feed-factory-ethereum-0xe08aff…aa61/` — zweryfikowane ABI
  (30 wpisów) i `provenance.json` z jawnym brakiem metadanych kompilatora
  implementacji.
- `deployments/1/factories.json` — drugi wpis, `kind: price-feed-factory`,
  status `verified`, zależność od price oracle middleware.
- `deployments/reports/ethereum-erc4626-price-feed-factory-f58fcce9-25937526.json`
  — raport weryfikacji.
- `test/deployed-factories/Erc4626PriceFeedFactoryEthereum.t.sol` — 2 testy
  `deployed-usage`.
- `config/test-suites.json` — nowa grupa `deployed-price-feed-factory`.
- `docs/deployments.md` — sekcja o drugim zweryfikowanym wpisie.

## Kroki

1. **Wybór i potwierdzenie tożsamości** — lookup → proxy i implementacja, slot ERC-1967, hashe kodu, właściciel; szczegóły w [`runs.txt`](runs.txt).
2. **ABI z explorera** — `contract_abi` dla implementacji; selektor `create(address,address)` potwierdzony w kodzie runtime.
3. **Test użycia** — feed dla Steakhouse USDC utworzony przez niezmienioną fabrykę; sprawdzone źródło (vault), jednostka (18 decimals, WAD) i wynik odczytu porównany z niezależnie przeliczoną wartością.
4. **Promocja do `verified`** — po teście i raporcie, tą samą procedurą co T26.

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| Jedna istniejąca fabryka price feedu: ABI, manifest, przykład użycia i test na forku | cztery artefakty wyżej; „przykład użycia" to sekcja w `docs/deployments.md` plus sam test | ✅ |
| Bez projektowania nowego oracle | nie dodano żadnego kontraktu; użyto wdrożonej fabryki i wdrożonego middleware | ✅ |
| Feed ma poprawne źródła | `feed.vault() == Steakhouse USDC`, a cena bierze się z tego vaulta i z middleware | ✅ |
| …jednostki | `decimals() == 18`; wartość porównana w WAD z przeliczeniem z `convertToAssets` i ceny USDC | ✅ |
| …i wynik odczytu | cena > 0, zgodna z przeliczeniem do 1 wei, w wiarygodnym przedziale dla udziału vaulta USDC | ✅ |
| Pochodzenie wersji potwierdzone | lookup + slot ERC-1967 + zweryfikowane ABI + hashe kodu w raporcie; brak gettera wersji zapisany jako `null` | ✅ |

## Odstępstwa od planu

- Ta fabryka nie ma gettera wersji, więc „wersja" to adres implementacji, hash
  kodu i ABI. Zapisane wprost w manifeście (`reportedVersion: null`) i w
  dokumentacji.
- Metadane kompilatora implementacji nie zostały pobrane (pobrano tylko ABI);
  `code.compiler` jest `null` zamiast skopiowanych ustawień proxy.

## Follow-upy (poza zakresem, NIE zrobione)

- Rejestracja utworzonego feedu w `PriceOracleMiddlewareManager` vaulta i test
  wyceny rynku przez ten feed — to konfiguracja strategii, nie fabryka feedów.
- `deployments:drift` obejmuje dziś tylko pierwszy wpis (domyślne
  `--deployment`); objęcie drugiego wymaga przebiegu z innym `--deployment` w
  workflow.

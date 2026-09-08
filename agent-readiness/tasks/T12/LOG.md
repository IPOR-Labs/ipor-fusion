# T12 — Instrukcje pracy nad fuse'ami

- **Status:** ready-for-commit
- **Data:** 2026-09-08 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 (1M context) przez Claude Code
- **Baza:** `git rev-parse --short HEAD` = `a92080a`, branch `feature/agents-support`
- **Zależności:** T08 (committed `f3b624f`), T09 (committed `1ea8233`)

## Zakres wykonany

Powstał jeden plik: `contracts/fuses/AGENTS.md` — instrukcja dla agentów i ludzi pracujących
nad fuse'ami, uzupełniająca root `AGENTS.md` dla `contracts/fuses/` i `contracts/rewards_fuses/`.
Dokument prowadzi od wyboru istniejącej integracji jako wzorca (ERC-4626 jako najmniejszy
kompletny przykład), przez cztery części integracji, ścieżkę wywołania z `PlasmaVault.execute`,
substrates, balance fuse i wycenę, checklistę zmiany, aż do doboru i uruchomienia testów.
Żaden fuse nie był refaktoryzowany — zmiana jest wyłącznie dokumentacyjna.

| Plik                        | Opis                                          |
| --------------------------- | --------------------------------------------- |
| `contracts/fuses/AGENTS.md` | nowy — instrukcje scoped dla katalogu fuse'ów |

## Kroki

1. **Uzgodnienie stanu z Git** — `git log -3 --format='%h %s'` → w trakcie sesji host zacommitował T11 jako `a92080a`; STATUS.md zaktualizowany z `ready-for-commit` na `committed a92080a`. T09 (`1ea8233`) i T10 (`4433979`) były już uzgodnione.
2. **Odczyt zależności i zakresu** — PLAN.md sekcje 3.1, 3.2 i blok `#### T12`; root `AGENTS.md`; `contracts/factory/AGENTS.md` jako wzorzec formy (T11).
3. **Weryfikacja ścieżki wywołania w kodzie** — `contracts/vaults/PlasmaVault.sol:389-420` (`execute`), `:1222-1246` (`executeInternal`), `:1065-1069` (`claimRewards`), `:1480-1491` (`_updateMarketsBalances`) → potwierdzone: `isFuseSupported` → `MARKET_ID()` → `functionDelegateCall` → aktualizacja sald i `AssetDistributionProtectionLib.checkLimits`. Potwierdzone też, że `claimRewards` **nie** wykonuje `isFuseSupported`.
4. **Weryfikacja interfejsów** — `IFuse.sol`, `IFuseCommon.sol`, `IMarketBalanceFuse.sol`, `IFuseInstantWithdraw.sol`, `ZeroBalanceFuse.sol` → `IFuse` deklaruje wariant `bytes`, a `Erc4626SupplyFuse` implementuje `IFuseCommon` + `IFuseInstantWithdraw` z ABI-typowanymi strukturami; ta różnica jest w dokumencie opisana wprost.
5. **Weryfikacja substrates** — `contracts/libraries/PlasmaVaultConfigLib.sol:41,85,188,250` → obie funkcje `grant*` najpierw wykonują `_revokeMarketSubstrates`, a obie funkcje `is*Granted` czytają to samo mapowanie `substrateAllowances`; oba fakty trafiły do dokumentu. Wzorzec pakowania: `contracts/fuses/balancer/BalancerSubstrateLib.sol:24-31` (typ w bitach powyżej 160).
6. **Weryfikacja balance fuse i wyceny** — `contracts/libraries/FusesLib.sol:382-396` (`addBalanceFuse`: `BalanceFuseAlreadyExists`, `BalanceFuseMarketIdMismatch`) i `:467-490` (`removeBalanceFuse`: `BalanceFuseNotReadyToRemove` powyżej dust); `contracts/vaults/lib/PlasmaVaultMarketsLib.sol:62` (`balanceOf()` przez `functionDelegateCall`) i `:164` (`getDependencyBalanceGraph`); `Erc4626BalanceFuse.balanceOf` jako wzorzec konwersji do WAD.
7. **Weryfikacja kształtu testów** — `test/fuses/PlasmaVaultMock.sol:59-110,259-288` → mock wywołuje fuse przez `functionDelegateCall` z literalną sygnaturą, np. `enter((address,uint256,uint256))`; stąd punkt 2 checklisty o stabilności układu struktur.
8. **Kontrola linków** — 12 ścieżek relatywnych z dokumentu przepuszczone przez `[ -e ]` → wszystkie istnieją, 0 broken. Dodatkowo sprawdzone istnienie 9 ścieżek wymienionych w tekście bez linku oraz 15 nazw symboli przez `grep -rl` w `contracts` i `test` → każda ma trafienia.
9. **Build** — `forge build` → `Compiler run successful` (tylko ostrzeżenia lintera, bez zmian w kodzie).
10. **Przejście instrukcji na jednej integracji (ERC-4626)** — `forge test --match-path 'test/fuses/erc4626/*'` → `23 tests passed, 0 failed, 0 skipped` w 3 suitach (`Erc4626SupplyFuseTest` 17, `Erc4626SupplyFuseWithFeeTest` 4, `ERC4646BalanceFuseTest` 2). Pełne wyjście: `forge-test-erc4626.txt`.
11. **Sprawdzenie tezy o `.env`** — probe w scratchpadzie (osobny mini-projekt Foundry): `env -u PROBE_VAR forge test` → wypisało wartość z `.env`; `PROBE_VAR=from_shell forge test` → wypisało `from_shell`. Wniosek: Foundry sam wczytuje `.env` z roota projektu, a zmienna już wyeksportowana ma pierwszeństwo. Pierwsza wersja akapitu o testach mówiła, że trzeba `set -a; . ./.env; set +a` — została poprawiona na zgodną z pomiarem.
12. **Formatowanie** — `./node_modules/.bin/prettier --check contracts/fuses/AGENTS.md` → `All matched files use Prettier code style!` (pre-commit formatuje też Markdown, więc plik jest już w docelowej postaci).
13. **Kontrola diffu** — `git status --short` → jedyna zmiana to `?? contracts/fuses/AGENTS.md` plus pliki procesowe tego zadania; żadnego formatowania cudzych plików.

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md)                                                                    | Sprawdzenie (komenda)                                                                                                                                                                 | Wynik |
| ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- |
| Powstaje `contracts/fuses/AGENTS.md`                                                     | `[ -e contracts/fuses/AGENTS.md ]`                                                                                                                                                    | ✅    |
| Wybór istniejącej integracji jako wzorca                                                 | dokument wskazuje `contracts/fuses/erc4626/` i `git ls-files 'contracts/**/README.md'` → 24 pliki                                                                                     | ✅    |
| Substrates opisane                                                                       | zgodne z `PlasmaVaultConfigLib.sol` (pełne zastąpienie listy, dwa kodowania, jedno mapowanie)                                                                                         | ✅    |
| Balance fuse opisany                                                                     | zgodne z `FusesLib.addBalanceFuse/removeBalanceFuse` i `PlasmaVaultMarketsLib`                                                                                                        | ✅    |
| Wyceny opisane                                                                           | zgodne z `Erc4626BalanceFuse.balanceOf` i `PlasmaVaultLib.getPriceOracleMiddleware`                                                                                                   | ✅    |
| Testy opisane                                                                            | `forge test --match-path 'test/fuses/erc4626/*'` → 23 passed / 0 failed                                                                                                               | ✅    |
| **Jedna istniejąca integracja pozwala przejść instrukcję od źródła do właściwego testu** | ERC-4626: `contracts/fuses/erc4626/{Erc4626SupplyFuse,Erc4626BalanceFuse}.sol` → `test/fuses/erc4626/` → `forge build` + `forge test --match-path 'test/fuses/erc4626/*'` → 23 passed | ✅    |
| Bez refaktoryzacji fuse'ów                                                               | `git status --short` → żaden plik `.sol` nie zmieniony                                                                                                                                | ✅    |
| Brak sekretów                                                                            | dokument podaje wyłącznie nazwę `ETHEREUM_PROVIDER_URL`, bez wartości                                                                                                                 | ✅    |
| Brak przypadkowego formatowania                                                          | `prettier --check` na jednym nowym pliku; `prettier:all` nie uruchamiane                                                                                                              | ✅    |

## Odstępstwa od planu

Brak. Zakres ograniczony do jednego pliku zgodnie z **Zakres**; `docs/README.md` i `.gitignore`
nie były ruszane, bo `contracts/` nie jest ignorowany i `AGENTS.md` jest odnajdywany po katalogu,
co root `AGENTS.md` już opisuje.

## Follow-upy (poza zakresem, NIE zrobione)

- Root `AGENTS.md` i `README.md` sugerują ręczne ładowanie `.env` do shella; pomiar w kroku 11
  pokazuje, że Foundry robi to sam. Warto to ujednolicić osobnym zadaniem — dotyczy też opisu
  w skillu `readiness-task`.
- `test/unitTest/fuses/` obejmuje tylko 3 integracje (`external_state`, `midas`, `term_finance`),
  więc reguła „najmniejszy test obok modułu" prawie zawsze prowadzi do testu forkowego. To jest
  materiał dla T13–T15 (katalog testów i zestaw bez RPC).
- Katalogi `contracts/fuses/` i `test/fuses/` rozjeżdżają się nazwami (`velodrome_superchain`
  vs `velodrome`, `curve_gauge` bez odpowiednika, `markl` vs `merkl` w `rewards_fuses`).
  Do rozważenia przy T19 (`test:affected`), które będzie mapować moduł na testy.
- `contracts/rewards_fuses/areodrome_slipstream/` ma literówkę w nazwie katalogu.

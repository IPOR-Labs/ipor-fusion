# Integracje do skatalogowania — lista TODO

Stan na 2026-09-09 (branch `feature/agents-support`, po commicie `b5775ed`). Lista wynika z
punktu 4 propozycji „dalsze usprawnienia” po zamknięciu T00–T52: katalog `catalog/fuses.json`
ma dziś **jeden** wpis (ERC4626, T33), a w kodzie jest 47 katalogów pod `contracts/fuses/`,
3 integracje chain-specific i 14 reward fuse'ów. Każdą robimy osobno, jeden wpis = jeden
commit, tym samym standardem co T33/T36.

## Definicja „zrobione” dla jednej integracji

1. Wpis w `catalog/fuses.json` (schemat `catalog/fuses.schema.json`): market ID i stała
   z `IporFusionMarkets.sol`, ABI `enter`/`exit` ze znaczeniem pól, kształt substrates,
   wycena (balance fuse, jednostki), role, lista testów; `interface.generated` przez
   `npm run catalog:generate`. `npm run validate:catalog` i `catalog:check` zielone.
2. Adresy fuse'ów wdrożonych na sieci pilotażu z poziomem dowodu `observed` (odczyt
   on-chain na bloku) albo jawnie `unknown`, bez zgadywania. Źródło: `fusion_address_lookup`
   (MCP) lub rejestr; zapisać sieć, adres, blok.
3. Rozbieżność ABI wdrożonego fuse'a wobec źródła w repo (jak `enter((address,uint256))`
   w T36) zapisana w katalogu i w `docs/troubleshooting.md`, jeśli występuje.
4. `README.md` obok źródeł, jeśli brakuje (kolumna README poniżej), w formacie istniejących
   README integracji.
5. Testy: klasyfikacja lokalny/fork w `config/test-suites.json` **tylko** jeśli suita ma
   trafić do `test:unit`/`test:fork`; w innym przypadku katalog wskazuje pliki testów bez
   klasyfikacji. Test `deployed-usage` (pełny cykl środków na niezmienionym vaulcie) robimy
   tylko dla integracji z priorytetem P1.
6. `docs/fuse-catalog.md` uzupełniony o wpis w tabeli, `validate:docs` zielony.

Nie robimy w ramach tej listy: refaktorów fuse'ów, zmian ABI, nowych integracji.

## Priorytety (propozycja do potwierdzenia)

Priorytet jest heurystyczny (liczba testów, obecność w produkcyjnych vaultach z pamięci
zespołu). Potwierdzone 2026-09-09: `vaults_list` (MCP) → 40 największych vaultów (TVL) na Ethereum, Base
i Arbitrum, `getFuses()` przez `cast` na przypiętych blokach, nazwy z rejestru `ipor-abi`
(`a0089cf`). Najczęstsze fuse'y: ERC4626 (47 wystąpień), BurnRequestFee (34),
UniversalTokenSwapper (29), Morpho flashloan/collateral/supply/borrow (20/19/15/14),
Aave V3 supply/borrow (15/8), Euler V2 supply (11). Kolejność P1 potwierdzona; swapper
`universal_token_swapper` podniesiony do P1. Źródło adresów: klon `IPOR-Labs/ipor-abi`
(`mainnet/mainnet-<chain>-fusion/addresses.json`, commit `a0089cf`, 2026-09-02) — MCP
`fusion_addresses_list` przekracza limit odpowiedzi. Bloki obserwacji: Ethereum 25939091,
Arbitrum 503330505, Base 51079414, Ink 55449764.

- **P1** — rynki, w których leżą środki produkcyjne: lending i ERC4626-podobne.
- **P2** — pozostałe integracje protokołowe (DEX-y, LP, staking, swappery).
- **P3** — fuse'y infrastrukturalne bez zewnętrznego protokołu (maintenance, erc20,
  transient storage itd.); wpis w katalogu ma tu głównie wartość dokumentacyjną.

## A. Integracje protokołowe (`contracts/fuses/<katalog>/`)

Kolumny: `.sol` = liczba plików źródłowych; `bal` = liczba balance fuse'ów; `README` = czy
istnieje; `fork` = pliki `test/fuses/<katalog>/*.t.sol`; `local` = pliki
`test/unitTest/fuses/<katalog>/*.t.sol`. Market ID wg `contracts/libraries/IporFusionMarkets.sol`.

| #   | Katalog                               | Market ID (stała)                                                                                    | .sol | bal | README | fork | local | Prio | Status                                                                           | Uwagi                                                                                                           |
| --- | ------------------------------------- | ---------------------------------------------------------------------------------------------------- | ---- | --- | ------ | ---- | ----- | ---- | -------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| 1   | `erc4626`                             | 100001–100020 (`ERC4626_0001`…)                                                                      | 2    | 1   | –      | 2    | 0     | P1   | **done** (T33, T34, T36)                                                         | wzorzec dla reszty; wdrożony fuse ma starsze ABI `enter((address,uint256))`                                     |
| 2   | `morpho`                              | 14 `MORPHO`, 19 `MORPHO_FLASH_LOAN`, 41 `MORPHO_LIQUIDITY_IN_MARKETS`, 200001–200010 `META_MORPHO_*` | 7    | 2   | –      | 5    | 0     | P1   | todo                                                                             | trzy market ID w jednym katalogu; MetaMorpho używa ERC4626 fuse'a                                               |
| 3   | `aave_v3`                             | 1 `AAVE_V3`, 20 `AAVE_V3_LIDO`                                                                       | 6    | 2   | –      | 6    | 0     | P1   | todo                                                                             | testy Ethereum + Arbitrum                                                                                       |
| 4   | `compound_v3`                         | 2 `COMPOUND_V3_USDC`, 13 `COMPOUND_V3_USDT`, 26 `COMPOUND_V3_WETH`                                   | 2    | 1   | –      | 7    | 0     | P1   | done (3 entries: ethereum-compound-v3-market-2, -13, base-compound-v3-market-26) | Ethereum fuses live in ipor-abi mainnet-ethereum/addresses.json (not \*-fusion); claim fuse has no MARKET_ID    |
| 5   | `euler`                               | 11 `EULER_V2`                                                                                        | 10   | 1   | y      | 13   | 0     | P1   | todo                                                                             | EVC-gated (patrz gotcha w wiki); EulerSwap bez fuse'a managera                                                  |
| 6   | `spark` (`chains/ethereum/spark`)     | 15 `SPARK`, 44 `SPARK_LEND`                                                                          | 2    | 1   | –      | 1    | 0     | P1   | todo                                                                             | `SparkSupplyFuse` + `SparkBalanceFuse`; testy w `test/fuses/spark/`                                             |
| 7   | `fluid_instadapp`                     | 5 `FLUID_INSTADAPP_POOL`, 6 `FLUID_INSTADAPP_STAKING`, 24 `FLUID_REWARDS`                            | 2    | 1   | –      | 0    | 0     | P1   | todo                                                                             | testy tylko w `test/integrationTest/fluidInstadappArbitrum/`                                                    |
| 8   | `gearbox_v3`                          | 3 `GEARBOX_POOL_V3`, 4 `GEARBOX_FARM_DTOKEN_V3`                                                      | 2    | 1   | –      | 0    | 0     | P2   | todo                                                                             | testy tylko w `test/integrationTest/gearboxV3Arbitrum/`                                                         |
| 9   | `moonwell`                            | 21 `MOONWELL`                                                                                        | 5    | 1   | –      | 2    | 0     | P2   | todo                                                                             | Base                                                                                                            |
| 10  | `aave_v2`                             | brak stałej w `IporFusionMarkets`                                                                    | 3    | 1   | –      | 2    | 0     | P2   | todo                                                                             | sprawdzić, jaki market ID używają testy                                                                         |
| 11  | `aave_v4`                             | 49 `AAVE_V4`                                                                                         | 5    | 1   | y      | 8    | 0     | P2   | todo                                                                             | IL-8054, spoke+reserveId substrates; brak wdrożeń (potwierdzić)                                                 |
| 12  | `compound_v2`                         | brak stałej                                                                                          | 2    | 1   | –      | 1    | 0     | P2   | todo                                                                             | jak aave_v2                                                                                                     |
| 13  | `silo_v2`                             | 35 `SILO_V2`                                                                                         | 6    | 1   | y      | 1    | 0     | P2   | todo                                                                             |                                                                                                                 |
| 14  | `dolomite`                            | 47 `DOLOMITE`                                                                                        | 6    | 1   | y      | 0    | 0     | P2   | todo                                                                             | brak testów w `test/fuses/` — znaleźć lub odnotować lukę                                                        |
| 15  | `midas`                               | 45 `MIDAS`                                                                                           | 5    | 1   | y      | 8    | 5     | P2   | todo                                                                             | ma suitę lokalną — kandydat do `test:unit`                                                                      |
| 16  | `term_finance`                        | 52 `TERM_FINANCE`                                                                                    | 9    | 1   | y      | 0    | 10    | P2   | todo                                                                             | tylko testy lokalne — kandydat do `test:unit`                                                                   |
| 17  | `pendle`                              | 23 `PENDLE`                                                                                          | 2    | 0   | –      | 1    | 0     | P2   | todo                                                                             | brak balance fuse'a w katalogu — ustalić, co wycenia PT/LP                                                      |
| 18  | `napier`                              | 46 `NAPIER`                                                                                          | 9    | 0   | y      | 1    | 0     | P2   | todo                                                                             | IL-8044 (slippage YT); brak balance fuse'a                                                                      |
| 19  | `curve_stableswap_ng`                 | 16 `CURVE_POOL`                                                                                      | 2    | 1   | –      | 2    | 0     | P2   | done                                                                             | Ethereum: SupplyFuse+BalanceFuse observed @25939091, selektory zgodne; README dodane; testy tylko fork Arbitrum |
| 20  | `curve_gauge`                         | 17 `CURVE_LP_GAUGE`, 25 `CURVE_GAUGE_ERC4626`                                                        | 3    | 2   | –      | 0    | 0     | P2   | todo                                                                             | testy w `test/integrationTest/curveGaugesArbitrum/`                                                             |
| 21  | `uniswap`                             | 8 `UNISWAP_SWAP_V3_POSITIONS`, 9 `UNISWAP_SWAP_V2`, 10 `UNISWAP_SWAP_V3`, 53 `UNISWAP_V4`            | 11   | 2   | y      | 5    | 0     | P2   | todo                                                                             | cztery market ID                                                                                                |
| 22  | `ramses`                              | 18 `RAMSES_V2_POSITIONS`                                                                             | 4    | 1   | –      | 2    | 0     | P2   | todo                                                                             | Arbitrum                                                                                                        |
| 23  | `aerodrome`                           | 30 `AERODROME`                                                                                       | 5    | 1   | y      | 1    | 0     | P2   | todo                                                                             | Base                                                                                                            |
| 24  | `aerodrome_slipstream`                | 33 `AREODROME_SLIPSTREAM`                                                                            | 6    | 1   | –      | 1    | 0     | P2   | todo                                                                             | IL-7958 (double counting); literówka `AREODROME` w stałej i w rewards                                           |
| 25  | `velodrome_superchain`                | 31 `VELODROME_SUPERCHAIN`                                                                            | 4    | 1   | y      | 0    | 0     | P2   | todo                                                                             | testy w `test/fuses/velodrome/` (inna nazwa katalogu)                                                           |
| 26  | `velodrome_superchain_slipstream`     | 32 `VELODROME_SUPERCHAIN_SLIPSTREAM`                                                                 | 6    | 1   | –      | 0    | 0     | P2   | todo                                                                             | jw.                                                                                                             |
| 27  | `balancer`                            | 36 `BALANCER`                                                                                        | 6    | 6   | y      | 1    | 0     | P2   | todo                                                                             | sześć balance fuse'ów — ustalić podział                                                                         |
| 28  | `stake_dao_v2`                        | 34 `STAKE_DAO_V2`                                                                                    | 2    | 1   | y      | 2    | 0     | P2   | todo                                                                             |                                                                                                                 |
| 29  | `liquity`                             | 29 `LIQUITY_V2`                                                                                      | 2    | 1   | y      | 1    | 0     | P2   | todo                                                                             |                                                                                                                 |
| 30  | `ebisu`                               | 39 `EBISU`                                                                                           | 7    | 1   | y      | 1    | 0     | P2   | todo                                                                             |                                                                                                                 |
| 31  | `yield_basis`                         | 37 `YIELD_BASIS_LT`                                                                                  | 2    | 1   | y      | 1    | 0     | P2   | todo                                                                             |                                                                                                                 |
| 32  | `agua`                                | 51 `AGUA_GLOBAL_CARRY`                                                                               | 5    | 1   | y      | 7    | 0     | P2   | todo                                                                             |                                                                                                                 |
| 33  | `tac`                                 | 28 `TAC_STAKING`                                                                                     | 5    | 1   | –      | 0    | 0     | P2   | todo                                                                             | sieć TAC; `TAC_PROVIDER_URL` puste na VM                                                                        |
| 34  | `lido` (`chains/ethereum/lido`)       | brak stałej                                                                                          | 1    | 0   | –      | 0    | 0     | P2   | todo                                                                             | `StEthWrapperFuse`; 4 testy odwołują się do lido w innych katalogach                                            |
| 35  | `litepsm` (`chains/ethereum/litepsm`) | 48 `LITE_PSM`                                                                                        | 1    | 0   | y      | 1    | 0     | P2   | todo                                                                             | testy w `test/fuses/litepsm/`                                                                                   |
| 36  | `universal_token_swapper`             | 12 `UNIVERSAL_TOKEN_SWAPPER`, 1202 `UNIVERSAL_TOKEN_SWAPPER_V2`                                      | 8    | 0   | –      | 10   | 0     | P1   | todo                                                                             | swapper, brak balance fuse'a; dwie stałe o tej samej wartości                                                   |
| 37  | `enso`                                | 38 `ENSO`                                                                                            | 4    | 1   | y      | 2    | 0     | P2   | todo                                                                             | IL-8048 (revoke allowance); delegatecall weiroll                                                                |
| 38  | `odos`                                | 42 `ODOS_SWAPPER`                                                                                    | 3    | 0   | y      | 1    | 0     | P2   | todo                                                                             | swapper                                                                                                         |
| 39  | `velora`                              | 43 `VELORA_SWAPPER`                                                                                  | 3    | 0   | y      | 1    | 0     | P2   | todo                                                                             | swapper                                                                                                         |
| 40  | `harvest`                             | 27 `HARVEST_HARD_WORK`                                                                               | 1    | 0   | –      | 1    | 0     | P2   | todo                                                                             |                                                                                                                 |
| 41  | `external_state`                      | 50 `EXTERNAL_STATE`                                                                                  | 6    | 1   | y      | 8    | 7     | P3   | todo                                                                             | ma suitę lokalną — kandydat do `test:unit`                                                                      |
| 42  | `async_action`                        | 40 `ASYNC_ACTION`                                                                                    | 4    | 1   | y      | 3    | 0     | P3   | todo                                                                             |                                                                                                                 |
| 43  | `erc20`                               | 7 `ERC20_VAULT_BALANCE`                                                                              | 1    | 1   | –      | 1    | 0     | P3   | todo                                                                             | tylko balance fuse                                                                                              |
| 44  | `update_balances`                     | –                                                                                                    | 2    | 2   | –      | 1    | 0     | P3   | todo                                                                             | infrastruktura                                                                                                  |
| 45  | `maintenance`                         | –                                                                                                    | 2    | 0   | –      | 1    | 0     | P3   | todo                                                                             | m.in. `UpdateWithdrawManagerMaintenanceFuse`                                                                    |
| 46  | `burn_request_fee`                    | –                                                                                                    | 2    | 0   | –      | 2    | 0     | P3   | todo                                                                             | powiązane z legacy slotem withdraw managera (IL-6952/7407)                                                      |
| 47  | `whitelist`                           | –                                                                                                    | 3    | 0   | –      | 1    | 0     | P3   | todo                                                                             |                                                                                                                 |
| 48  | `plasma_vault`                        | –                                                                                                    | 2    | 0   | –      | 1    | 0     | P3   | todo                                                                             | fuse'y operujące na innym PlasmaVaulcie (m.in. request shares)                                                  |
| 49  | `transient_storage`                   | –                                                                                                    | 3    | 0   | –      | 3    | 0     | P3   | todo                                                                             | łańcuchowanie fuse'ów; `isolate = false` w foundry.toml                                                         |

Katalogi testów bez odpowiednika w `contracts/fuses/`: `test/fuses/markl` (reward fuse
Merkl, literówka), `test/fuses/syrup` (reward fuse Syrup), `test/fuses/velodrome`,
`test/fuses/spark`, `test/fuses/litepsm`. Zaznaczyć w katalogu ścieżki testów jawnie.

## B. Reward fuse'y (`contracts/rewards_fuses/<katalog>/`)

Reward fuse wchodzi do wpisu integracji, do której należy (kolumna „Wpis w A”), nie jako
osobny wpis. Nie ma katalogu `test/rewards_fuses/`; testy są tam, gdzie wskazano.

| #   | Katalog                | .sol | Wpis w A                   | Testy                                                                                                                  | Status                     |
| --- | ---------------------- | ---- | -------------------------- | ---------------------------------------------------------------------------------------------------------------------- | -------------------------- |
| R1  | `morpho`               | 1    | 2                          | `test/fuses/morpho/MorphoClaimFuseTest.t.sol`                                                                          | todo                       |
| R2  | `compound`             | 2    | 4                          | `test/fuses/compound_v3/CompoundV3ClaimFuseTest.t.sol`                                                                 | done (in entries of row 4) |
| R3  | `euler`                | 1    | 5                          | `test/fuses/euler/RewardEulerTokenClaimFuseTest.t.sol`                                                                 | todo                       |
| R4  | `fluid_instadapp`      | 2    | 7                          | `test/integrationTest/fluidInstadappArbitrum/…ClaimRewards.t.sol`, `test/fuses/moonwell/FluidProofClaimFuseTest.t.sol` | todo                       |
| R5  | `gearbox_v3`           | 1    | 8                          | `test/integrationTest/gearboxV3Arbitrum/…ClaimRewards.t.sol`                                                           | todo                       |
| R6  | `moonwell`             | 1    | 9                          | tylko pośrednio w `test/context/ContextManagerRewardsClaimManagerTest.t.sol`                                           | todo                       |
| R7  | `curve_gauges`         | 1    | 20                         | `test/integrationTest/curveGaugesArbitrum/…ClaimLPGaugeArbitrum.t.sol`                                                 | todo                       |
| R8  | `ramses`               | 1    | 22                         | `test/fuses/ramses/RamsesClaimFuseTest.t.sol`                                                                          | todo                       |
| R9  | `aerodrome`            | 1    | 23                         | `test/fuses/aerodrome/AerodromeFuseTests.t.sol`                                                                        | todo                       |
| R10 | `areodrome_slipstream` | 1    | 24                         | `test/fuses/aerodrome_slipstream/AreodromeSlipstreamTest.t.sol`                                                        | todo                       |
| R11 | `velodrome_superchain` | 2    | 25, 26                     | `test/fuses/velodrome/*.t.sol`                                                                                         | todo                       |
| R12 | `stake_dao_v2`         | 1    | 28                         | `test/fuses/stake_dao_v2/StakeDaoV2FuseTest.t.sol`                                                                     | todo                       |
| R13 | `merkl`                | 2    | przekrojowy (Euler i inne) | `test/fuses/markl/*.t.sol`                                                                                             | todo                       |
| R14 | `syrup`                | 1    | brak fuse'a akcji w repo   | `test/fuses/syrup/SyrupClaimFuseTest.t.sol`                                                                            | todo                       |

Market ID `22 MORPHO_REWARDS` i `424 SPOL_UNSTAKE` nie mają katalogu w `contracts/fuses/`;
ustalić przy wpisach Morpho i TAC, czy są martwe.

## C. Porządki wykryte przy tworzeniu listy (osobne, małe zadania)

- Niespójne nazwy: `contracts/fuses/velodrome_superchain*` vs `test/fuses/velodrome`,
  `contracts/rewards_fuses/areodrome_slipstream` (literówka) vs
  `contracts/fuses/aerodrome_slipstream`, `test/fuses/markl` vs `rewards_fuses/merkl`.
  Wpływa na graf importów w `test:affected` i na wyszukiwanie testów przez agenta.
- `UNIVERSAL_TOKEN_SWAPPER` = 12, `UNIVERSAL_TOKEN_SWAPPER_V2` = `12_02` = 1202 (nie ten sam ID, jak
  pierwotnie zapisano w tej liście).
- `aave_v2`, `compound_v2`, `lido` nie mają stałej w `IporFusionMarkets.sol`.
- Suity lokalne (`midas`, `term_finance`, `external_state`) nie są w
  `config/test-suites.json`, więc `test:unit` ich nie uruchamia.

## Proces

Jeden wpis = jedno zadanie = jeden commit `feat(catalog): add <protocol> integration`.
Przed startem wpisu: `git status` czysty, `npm run validate:catalog` zielony. Po wpisie:
`catalog:generate`, `validate:catalog`, `catalog:check`, `validate:docs`, aktualizacja kolumny
Status w tej tabeli (`todo` → `done`) w tym samym commicie; hash to ten commit (`git log --
agent-readiness/INTEGRATIONS-TODO.md` pokazuje go po fakcie, w commicie nie da się go wpisać).

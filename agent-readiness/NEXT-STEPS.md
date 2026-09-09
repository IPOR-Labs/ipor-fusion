# Dalsze usprawnienia po T00–T52

Lista zaproponowana 2026-09-09 po weryfikacji, że T01–T52 są zacommitowane i wszystkie
kontrole przechodzą (walidatory, testy narzędzi, `test:unit`). Kolejność = wartość dla
agenta. Statusy: `todo` · `in-progress` · `done <hash>`. Aktualizuje agent w tym samym
commicie, który zamyka punkt.

| #   | Usprawnienie                                                                                                                                                                                                                                                                        | Status                    | Uwagi                                                                            |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------- | -------------------------------------------------------------------------------- |
| 1   | **Pomiar (T00 run 1 + T48 run 2).** Osiem zadań z sekcji 10 `PLAN.md` w sesjach `--bare` bez prywatnej pamięci, na commicie sprzed serii i na `HEAD`. Wymaga `ANTHROPIC_API_KEY` na maszynie pomiarowej. Jedyna rzecz, która zamyka etap pierwszy.                                  | todo                      | osobny branch decyzją Pete'a (2026-09-07); przepis w `tasks/T01/LOG.md`          |
| 2   | **Zamknięcie baseline'u formatowania.** 303 pliki z odchyleniem, `format:check` w CI tylko raportował. Jeden commit `prettier:all`, potem gating i pre-commit bez wyjątków.                                                                                                         | done `764332c`, `7e3846d` | bytecode bez metadanych identyczny przed/po (1235 artefaktów)                    |
| 3   | **AGENTS.md dla `contracts/vaults/`, `contracts/managers/`, `contracts/price_oracle/`.** Najbardziej ryzykowna strefa (storage, delegatecall, role) miała tylko reguły z root AGENTS.md.                                                                                            | done `b5775ed`            | m.in. rozmiar `PlasmaVault` 23908 B przy 200 runs vs 31962 B w profilu domyślnym |
| 4   | **Katalog integracji.** `catalog/fuses.json` ma jeden wpis (ERC4626). Kolejne po jednej na zadanie, od używanych w produkcji, standard: `observed` na bloku, ABI wdrożonego fuse'a vs źródło.                                                                                       | in-progress               | pełna lista i statusy: [INTEGRATIONS-TODO.md](INTEGRATIONS-TODO.md) (`8157ad8`)  |
| 5   | **Luki z `docs/invariants.md`** (11 własności `postulated`). Cztery z T37: W1 (redeem przed redemption delay rewertuje), P4 (wdrożony fuse odrzuca substrate spoza listy), P5 (`MarketLimitExceeded` w commitowanym teście), A6 (narastanie wartości na forku z dwoma blokami).     | todo                      | każda luka = jeden test = jeden commit                                           |
| 6   | **Dekoder rewertów.** `vault:simulate` i `docs/troubleshooting.md` nie dekodują powodu rewertu. Mapa selektorów custom errors z `out/` na nazwy plus tabela w docs.                                                                                                                 | todo                      | follow-up T38                                                                    |
| 7   | **Schematy artefaktów planu, symulacji i preflightu.** Manifesty i konfiguracje mają schematy, artefakty narzędzi nie; journal z T40 łączy pliki o niezdefiniowanym kształcie.                                                                                                      | todo                      | follow-up T28/T29/T39                                                            |
| 8   | **Drift dla wszystkich wpisów `verified`.** `deployments:drift` domyślnie sprawdza Ethereum FusionFactory; price feed factory, wrapper i Base wymagają jawnych flag i nie są w `pilot-drift.yml`.                                                                                   | todo                      | follow-up T46/T49/T51                                                            |
| 9   | **Higiena zależności.** `npm audit --omit=dev`: 29 podatności (1 critical, 9 high). Osobny commit z podbiciem lockfile.                                                                                                                                                             | todo                      | follow-up T03                                                                    |
| 10  | **Spójność nazw katalogów.** `contracts/fuses/velodrome_superchain*` vs `test/fuses/velodrome`, literówka `contracts/rewards_fuses/areodrome_slipstream/`, `test/fuses/markl` vs `rewards_fuses/merkl`. Pułapka dla grafu importów `test:affected` i dla agenta szukającego testów. | todo                      | szczegóły w sekcji C [INTEGRATIONS-TODO.md](INTEGRATIONS-TODO.md)                |
| 11  | **Uruchomienie workflow w GitHub Actions.** `pr-checks.yml`, `pilot-fork-checks.yml` i `pilot-drift.yml` przeszły tylko lokalnie. Ochrona environment `external` i wymóg review od CODEOWNERS do potwierdzenia w ustawieniach GitHub po pushu.                                      | todo                      | wymaga pushu z hosta; VM nie ma poświadczeń GitHub                               |

## Nieścisłości do poprawienia przed merge (poza numeracją)

- `AGENTS.md` linie 15–16: mówi o jednym manifeście `candidate` i braku konfiguracji
  vaulta oraz recept; dziś są 4 wpisy `verified`, `config/vaults/`, 3 recepty i katalog.
- `agent-readiness/README.md`: nadal mówi, że `.git` w VM jest read-only i agent nigdy nie
  commituje; `ENVIRONMENT.md` i commit `43bc189` mówią, że jest zapisywalny.
- Commit T00 `7d64650` ma jako tytuł nagłówek pliku COMMIT.md; do naprawy tylko rebase,
  raczej do zaakceptowania.
- NatSpec niezgodny z kodem (wykryte przy punkcie 3): `WithdrawManager.updateWithdrawFee`
  i `updateRequestFee` mówią `ATOMIST_ROLE`, initializer wiąże role 901/902;
  `ERC4626PriceFeedFactory.create` nazywa parametr middleware „currently unused”, a kod go
  używa; komentarz `PlasmaVaultInitData.withdrawManager` mówi, że zero wyłącza managera, a
  initializer rewertuje `WithdrawManagerNotSet`.
- Namespace'y OpenZeppelin kopiowane w `PlasmaVaultVotesPlugin` nie mają testu slotów.

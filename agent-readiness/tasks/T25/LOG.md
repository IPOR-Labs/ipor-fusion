# T25 — Test tworzenia przez niezmienioną fabrykę

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Codex
- **Baza:** `562fea3`, branch `feature/agents-support`
- **Zależności:** T16 (`3f68cf7`), T24 (`562fea3`)

## Zakres wykonany

- Dodano jedyny sklasyfikowany test `deployed-usage` dla Ethereum FusionFactory
  w `test/deployed-factories/FusionFactoryEthereum.t.sol`.
- Test używa minimalnego interfejsu zgodnego z 78-elementowym ABI implementacji
  T22. Wywołuje permissionless `clone` na niezmienionym proxy z bloku
  `25937526`; caller i żądany owner są różnymi adresami.
- Fixture nie robi upgrade'u, `vm.etch`, podmiany komponentów, finansowania
  konta ani nadania roli. Jedyną mutacją związaną z istniejącym deploymentem
  jest normalne wywołanie `clone`; utworzone kontrakty istnieją wyłącznie w
  efemerycznym stanie forka.
- Asercje obejmują inkrementację indeksu, wersję 8, bazę i asset USDC, metadata,
  kod siedmiu zwróconych komponentów, `OWNER_ROLE` dla żądanego ownera oraz
  management/performance/recipient z pakietu 0 efektywnego dla bezpośredniego
  callera.
- Katalog ma teraz ósmy suite i oddzielną grupę CLI `deployed-factory` z
  fixture `deployed-usage`, właściwym blokiem, providerem i ograniczeniem
  zakresu dowodu. Dokumentacja rozdziela go od dwóch fork-fresh suite.

## Weryfikacja

Wyniki są zapisane w `runs.txt`.

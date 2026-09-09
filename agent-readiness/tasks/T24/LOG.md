# T24 — Odczyt i weryfikacja tożsamości fabryki

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Codex
- **Baza:** `c982350`, branch `feature/agents-support`
- **Zależności:** T18 (`5f70266`), T23 (`c982350`)

## Zakres wykonany

- Dodano `factory:inspect` z obowiązkowym chain ID, ID deploymentu, numerem
  bloku i callerem. Provider pochodzi z katalogu testów i środowiska/`.env`,
  ale jego wartość nie trafia do argumentów procesów ani diagnostyki.
- Inspektor sprawdza chain ID providera, dostępność historycznego bloku, kod
  proxy, slot ERC-1967, zgodność implementacji, jej kod oraz hash ABI przed
  dekodowaniem getterów.
- Raport obejmuje hash bloku i obu runtime'ów, wersję fabryki, fabryki
  składowe, bazy, middleware/oraz burn fuses, okna czasowe, globalne pakiety
  opłat i efektywne pakiety dla jawnego callera.
- Zapisano rzeczywisty odczyt Ethereum z bloku `25937526` w
  `factory-inspection.json`. Manifest pozostaje `candidate` i nie został
  automatycznie zmieniony przez inspekcję.
- Testy mock-RPC odróżniają `CHAIN_MISMATCH`, `NO_CODE`,
  `IMPLEMENTATION_MISMATCH` oraz `UNSUPPORTED_FACTORY_VERSION` i sprawdzają
  redakcję szczegółów providera.
- Odczyt na starszym bloku katalogowym `23831825` celowo kończy się
  `IMPLEMENTATION_MISMATCH`: proxy wskazywało tam
  `0xD48d9528581B6bbc5e259f1e3720619bB55D5E0d`, nie implementację kandydata.

## Weryfikacja

Wyniki są zapisane w `runs.txt`.

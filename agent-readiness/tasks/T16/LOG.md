# T16 — Uruchamianie jednego zestawu na forku

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Codex
- **Baza:** `b0bbd2a`, branch `feature/agents-support`
- **Zależności:** T13 (`2b3e415`), T14 (`212a6e6`)

## Zakres wykonany

- `npm run test:fork -- --chain 1 --suite factory --block <number>` wybiera
  fixture'y forkowe z katalogu po `chainId` i `group`.
- Runner waliduje argumenty i katalog, wymaga dokładnie jednego providera i
  profilu, ładuje ignorowany `.env` bez wypisywania wartości oraz propaguje
  kod błędu Forge.
- Oba fixture'y odczytują blok z `FUSION_FORK_BLOCK` (z zachowaniem
  katalogowego fallbacku dla ręcznych wywołań) i mają jawny test porównujący
  `block.number` z żądaniem runnera.
- Katalog i schemat zyskały pola `group` i `chainId`; liczba testów forkowych
  wzrosła z 10 do 12.
- Testy Node pokrywają brak RPC, niewspieraną sieć, niewspieraną suitę,
  przekazanie bloku i obu ścieżek do Forge oraz kontrakt fixture–runner.

## Weryfikacja

Wyniki są zapisane w `runs.txt`.

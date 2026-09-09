# T14 — Jawne profile uruchamiania testów

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Codex
- **Baza:** `2b3e415`, branch `feature/agents-support`
- **Zależności:** T13 (committed `2b3e415`)

## Zakres wykonany

- `foundry.toml` jawnie definiuje profile `ci`, `factory_local`,
  `factory_ethereum` i `arbitrum`.
- Profile pilotażu fabryki dziedziczą kompilator, optimizer, Cancun oraz
  `isolate = false` z `default`, ale ustawiają `ffi = false` i puste
  `fs_permissions`.
- Profil `ci` zachowuje poprzednią efektywną konfigurację `default`, ponieważ
  istniejący workflow uruchamia również niesklasyfikowane testy.
- Profil `arbitrum` nadal różni się wyłącznie `evm_version = "paris"`.
- Katalog siedmiu suit wybiera ograniczone profile, a dokumentacja pokazuje
  efektywną macierz ustawień i wymaga jawnego `FOUNDRY_PROFILE`.

## Weryfikacja

Wyniki komend i porównanie efektywnych konfiguracji zapisano w `runs.txt`.
Sprawdzono walidator katalogu, build oraz wszystkie 129 lokalnych i 10 forkowych
testów pilotażu z profilami wskazanymi przez katalog.

Nie zmieniono `solc`, `optimizer_runs`, `evm_version` żadnego istniejącego
przypadku użycia ani globalnego `isolate`. Nie zmieniono plików Solidity.

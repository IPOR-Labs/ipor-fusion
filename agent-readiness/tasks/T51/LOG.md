# T51 — Jedna dodatkowa sieć dla istniejącej wersji

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 przez Claude Code
- **Baza:** `562fea3`, branch `feature/agents-support`
- **Zależności:** T16 (`3f68cf7`), T24 (`562fea3`), T32, T44 (ready-for-commit)

## Zakres wykonany

Base (chain 8453) dla tej samej rodziny ABI (wersja fabryki 8).

- `deployments/8453/factories.json` — manifest sieci, wpis `verified`.
- `abi/fusion-factory-base-0x610152…33b7/` — plik ABI (identyczny bajtowo z
  ethereumowym) i `provenance.json` z powodem ponownego użycia, dowodami i
  granicami.
- `deployments/reports/base-fusion-factory-14557176-51000000.json` — raport.
- `test/deployed-factories/FusionFactoryBase.t.sol` — test `deployed-usage`.
- `foundry.toml` — profil `factory_base` (tylko `ffi=false`, puste
  `fs_permissions`; bez zmian kompilatora).
- `config/test-suites.json` i `config/test-suites.schema.json` — suita dla 8453 i
  nowy profil w enumie.
- `docs/deployments.md` — sekcja „A second network: Base".

## Kroki

1. **Wybór sieci** — Base ma skonfigurowany provider i fabrykę w tej samej wersji (8).
2. **Tożsamość i przypięty blok** — slot ERC-1967, hashe kodu, hash bloku 51000000; wszystko w [`runs.txt`](runs.txt).
3. **Zgodność ABI** — ta sama wersja raportowana, probe 42/43 selektorów, a 43. potwierdzony realnym wywołaniem; różnica bytecode'u zapisana wprost.
4. **Test i runner** — test przechodzi przez `test:fork --chain 8453`, a wybór dla Ethereum działa dalej bez zmian.

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| Dla tej samej rodziny ABI: jedna sieć, manifest, profil wyboru testów i jeden test użycia | cztery artefakty + profil `factory_base` | ✅ |
| Pełna recepta działa na drugiej sieci bez mieszania adresów/tokenów | test tworzy vault na Base USDC przez adres Base i asertuje, że adresy sieci są różne; `agent:doctor --rpc --chain 8453` przechodzi | ✅ |
| Nie zmieniać parametrów kompilacji bez uzgodnienia | `factory_base` ustawia wyłącznie `ffi` i `fs_permissions`; solc, optimizer i EVM bez zmian | ✅ |
| Inne ABI wymaga osobnego zadania adaptera | zapisane w `docs/deployments.md`: `factory:inspect` nie jest podpięty do tej sieci, a inna rodzina ABI wymaga adaptera | ✅ |

## Odstępstwa od planu

- „Pełna recepta" na Base ogranicza się do utworzenia vaulta. Konfiguracja
  strategii wymagałaby katalogu fuse'ów dla Base (osobne zadanie w stylu T33) —
  nie rozszerzam tego zadania na kolejne wdrożenia.
- ABI jest ponownie użyte zamiast pobrane z explorera dla implementacji Base;
  powód, dowody i ograniczenia są w `provenance.json`.

## Follow-upy (poza zakresem, NIE zrobione)

- `factory:inspect` i `deployments:drift` dla Base (dziś domyślnie Ethereum).
- Katalog integracji i strategia na Base.
- Zweryfikowane ABI implementacji Base z explorera, jeśli będzie potrzebne poza
  ścieżką `clone`.

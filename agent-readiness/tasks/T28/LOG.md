# T28 — Plan jednej operacji utworzenia

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 przez Claude Code
- **Baza:** `562fea3`, branch `feature/agents-support`
- **Zależności:** T24 (`562fea3`), T27 (ready-for-commit)

## Zakres wykonany

`vault:plan` zamienia zwalidowane wejście i jeden historyczny blok w artefakt
planu — bez podpisywania i wysyłania.

- `tools/plan-vault.mjs` — `vault:plan --config <plik> --block <n> [--out <plik>]`;
  buduje calldata przez `cast`, dokłada zdekodowane argumenty, `to`/`from`/`value`,
  odczytaną implementację i wersję, pakiet opłat efektywny dla callera, numer i
  hash bloku oraz SHA-256 wejścia.
- `tools/lib/chain.mjs` — wspólny dostęp read-only: nazwa zmiennej providera z
  katalogu testów, JSON-RPC z timeoutem, `cast`, sygnatury i `eth_call` na
  przypiętym bloku. URL providera nigdy nie trafia do wyjścia.
- `tools/test-plan-vault.mjs` — 14 testów na lokalnym, udawanym serwerze RPC.
- `tools/lib/vault-config.mjs` — dodany override `FUSION_DEPLOYMENTS_DIR`, żeby
  dało się sprawdzić wejście wobec innego (np. tymczasowego) rejestru.
- `tools/test-validate-vault-config.mjs` — dodany test odrzucenia wpisu
  `candidate` (18 testów).
- `docs/vaults.md` — sekcja „Planning one creation": artefakt, kontrola calldata
  i tabela wszystkich powodów zatrzymania planowania.
- `package.json` — `vault:plan` i `vault:plan:test`.

## Kroki

1. **Plan na realnym providerze** — `npm run vault:plan -- --config config/vaults/example.json --block 25937526` → artefakt z implementacją `0xf19C…63f5`, wersją `8` i pakietem `dao-global[0]`.
2. **Kontrola calldata** — `cast decode-calldata "clone(string,string,address,uint256,address,uint256)" <data>` → sześć wartości identycznych z wejściem.
3. **Testy planera** — `npm run vault:plan:test` → 14/14; wszystkie ścieżki odmowy w [`runs.txt`](runs.txt).
4. **Testy wejścia** — `npm run validate:vault-config:test` → 18/18.
5. **Regresja rejestru** — `npm run validate:deployments` → pass.

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| Calldata dekoduje się do danych wejściowych | `cast decode-calldata …` oraz test „the plan's calldata decodes back to the configured inputs" | ✅ |
| Adres docelowy, caller i value w planie | pola `transaction.to/from/value` (`"0"`) | ✅ |
| Oczekiwana implementacja i opłaty | `expected.implementation`, `expected.factoryVersion`, `expected.feePackage` | ✅ |
| Blok odczytu i hash wejścia | `readBlock.number/hash`, `input.sha256` | ✅ |
| Manifest niezweryfikowany zatrzymuje planowanie | test z tymczasowym rejestrem `candidate` → `UNVERIFIED_DEPLOYMENT`, exit 1, bez RPC | ✅ |
| Niezgodność wersji zatrzymuje planowanie | test „version 9" → `UNSUPPORTED_FACTORY_VERSION` | ✅ |
| Zły pakiet opłat zatrzymuje planowanie | cztery testy: wartości, odbiorca, źródło listy, indeks poza zakresem → `FEE_PACKAGE_MISMATCH` | ✅ |
| Bez podpisywania i wysyłania | narzędzie wykonuje wyłącznie `eth_chainId`, `eth_getBlockByNumber`, `eth_getStorageAt` i `eth_call`; brak klucza, brak `--broadcast` | ✅ |

## Odstępstwa od planu

- Plan przewiduje też „przewidywaną kolejność transakcji". Dla pilotażu
  operacja jest jedna (`clone`), więc artefakt nie ma listy kroków; wieloetapowe
  sekwencje pojawią się dopiero przy konfiguracji strategii (T35).
- Kod błędu dla opłat nazwano `FEE_PACKAGE_MISMATCH` (rozbieżność planu z
  odczytem). `FEE_PACKAGE_CHANGED` z sekcji 8.2 opisuje zmianę po zbudowaniu
  planu i należy do preflightu (T39).

## Follow-upy (poza zakresem, NIE zrobione)

- `tools/inspect-factory.mjs` ma własne kopie funkcji, które są już w
  `tools/lib/chain.mjs`; migracja to osobne zadanie porządkowe.
- Artefakt planu nie ma schematu ani walidatora — potrzebny, gdy plan zacznie
  być wejściem symulacji (T29) i preflightu (T39).
- `tools/lib/affected-tests.mjs` nie zna nowych plików w `tools/` i `config/vaults/`.

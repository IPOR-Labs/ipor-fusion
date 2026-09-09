# T26 — Promocja pilotażu do verified

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 przez Claude Code
- **Baza:** `562fea3`, branch `feature/agents-support`
- **Zależności:** T24 (`562fea3`), T25 (ready-for-commit)

## Zakres wykonany

Pilotażowy wpis Ethereum FusionFactory ma status `verified`, oparty na
odtwarzalnym, pozbawionym sekretów raporcie na bloku `25937526`.

- `deployments/reports/ethereum-fusion-factory-cd05909c-25937526.json` — nowy
  raport weryfikacji: blok i jego hash, wersje narzędzi (forge/cast 1.7.1, node,
  npm), SHA-256 skryptu inspektora i pliku testu, komendy odtworzenia, tożsamość
  proxy/implementacji, hash ABI, odtworzone odczyty konfiguracji, kod runtime z
  hashem pod wszystkimi 16 adresami komponentów oraz wynik testu zgodności.
- `deployments/1/factories.json` — status `candidate` → `verified`; uzupełnione
  hashe runtime proxy i implementacji, `reportedVersion` `"8"`, 16 zależności
  oraz komplet pól `verification`.
- `.gitignore` — wyjątek `!deployments/reports/`, bo globalny wzorzec `reports/`
  ignorował katalog z dowodami.
- `docs/deployments.md` — nowa sekcja „Verification record" (co dokładnie
  udowodniono, jak odtworzyć, kiedy wpis wraca do `candidate`), zaktualizowany
  status pilotażu i sekcja braków po weryfikacji.
- `agent-readiness/tasks/T26/` — LOG, COMMIT, komunikat commita i `runs.txt`.

## Kroki

1. **Odtworzenie odczytów on-chain** — `node tools/inspect-factory.mjs --chain 1 --deployment ethereum-fusion-factory-cd05909c --block 25937526 --caller 0x1111111111111111111111111111111111111111` → treść identyczna z zapisem T24 (różni się tylko wcięciem JSON).
2. **Sprawdzenie kodu komponentów** — `cast code --block 25937526 <adres>` dla 16 adresów z odczytu → wszystkie mają niepusty kod; rozmiary 167–23888 B, keccak256 zapisane w raporcie.
3. **Test zgodności** — `npm run test:fork -- --chain 1 --suite deployed-factory --block 25937526` → `[PASS] testCreateVaultThroughUnchangedPilotFactory() (gas: 8905074)`.
4. **Zapis raportu** — złożony z wyników kroków 1–3 plus wersje narzędzi; provider tylko jako nazwa zmiennej `ETHEREUM_PROVIDER_URL`.
5. **Odblokowanie katalogu w `.gitignore`** — `git check-ignore -v deployments/reports/x.json` przed zmianą wskazywał `reports/`, po zmianie brak dopasowania (exit 1).
6. **Promocja manifestu i walidacja** — `npm run validate:deployments` → `2 checked (1 production, 1 fixture)`.
7. **Kontrola negatywna** — kopia manifestu z `verification.blockHash = null` → `verified deployment requires blockHash`, exit 1.
8. **Regresje narzędzi** — `npm run validate:deployments:test` (7) i `npm run factory:inspect:test` (4) → pass.

Pełne wyjścia: [`runs.txt`](runs.txt).

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| Raport odczytów i testu bez sekretów | `grep -rniE "https?://" deployments/reports/` → brak URL-i providera; w raporcie tylko nazwa zmiennej | ✅ |
| Numer i hash bloku oraz wersje narzędzi zapisane | pola `blockNumber`, `blockHash`, `toolchain` w raporcie i `verification` w manifeście | ✅ |
| Zmieniony status jednego manifestu | `deployments/1/factories.json` → `verified`; drugi (fixture) bez zmian | ✅ |
| `verified` odsyła do odtwarzalnego dowodu, nie do zapewnienia w dokumencie | `npm run validate:deployments` wymusza komplet pól; kontrola negatywna odrzuca brak `blockHash`; raport zawiera komendy odtworzenia, a odczyt i test uruchomiono ponownie w tym zadaniu | ✅ |

## Odstępstwa od planu

- Poza samą zmianą statusu uzupełniono w manifeście hashe runtime,
  `reportedVersion` i `dependencies`. Bez tego wpis `verified` nie miałby w
  sobie danych, które raport dopiero co potwierdził, a sekcja 5.1 planu wymaga
  ich dla zweryfikowanego wdrożenia.
- Wyjątek w `.gitignore` był konieczny: schemat wymaga `reportPath` w
  `deployments/reports/`, a ten katalog był ignorowany.

## Follow-upy (poza zakresem, NIE zrobione)

- `tools/inspect-factory.mjs` nie sprawdza kodu pod adresami komponentów —
  zrobiono to tu ręcznie przez `cast`. Automatyczna kontrola driftu komponentów
  należy do T46.
- Raport weryfikacji nie ma własnego schematu ani walidatora; `validate:deployments`
  sprawdza tylko istnienie pliku. Kandydat do T45.
- `docs/testing.md` nadal opisuje proxy jako „candidate"; pliku celowo nie
  ruszano, bo należy do niezacommitowanego T25.

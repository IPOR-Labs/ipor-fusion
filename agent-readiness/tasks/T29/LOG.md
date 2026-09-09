# T29 — Symulacja przygotowanego planu

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 przez Claude Code
- **Baza:** `562fea3`, branch `feature/agents-support`
- **Zależności:** T25 (ready-for-commit), T28 (ready-for-commit)

## Zakres wykonany

`vault:simulate` wykonuje dokładnie calldata z planu na efemerycznym forku
`anvil` na przypiętym bloku, jako caller wskazany w planie.

- `tools/simulate-vault.mjs` — `vault:simulate --plan <plik> [--block <n>] [--out <plik>]`;
  raport z `success`/`reverted`, gas, blokiem i hashem forka, SHA-256 planu i
  wejścia oraz adresami utworzonych komponentów.
- `tools/lib/fork.mjs` — cykl życia forka: wolny port, `anvil --fork-url
  --fork-block-number`, oczekiwanie na gotowość, kontrola chain ID, twarde
  zabicie procesu na końcu i przy błędzie.
- `tools/test-simulate-vault.mjs` — 7 testów; forkowe pomijane, gdy brak
  `ETHEREUM_PROVIDER_URL` (nie „przechodzą po cichu").
- `docs/vaults.md` — sekcja „Simulating the plan": co raport zawiera, skąd
  pochodzi sygnatura eventu i czego symulacja celowo nie robi.
- `package.json` — `vault:simulate` i `vault:simulate:test`.

## Kroki

1. **Ścieżka wykonania** — wybrany `anvil` + impersonacja, bo tylko realna transakcja na forku daje receipt, logi i trwały stan potrzebny w T30/T31; `cast call --trace` daje gas, ale nie stan po operacji.
2. **Przebieg** — `node tools/simulate-vault.mjs --plan <plan>` → `success`, gas 8873940, blok 25937526.
3. **Zgodność dwóch odczytów** — adresy z return value (`eth_call` na stanie sprzed transakcji) i z eventu `FusionInstanceCreated` są porównywane; rozbieżność to `SIMULATION_INCONSISTENT`.
4. **Sygnatura eventu** — wdrożone ABI (78 wpisów) nie zawiera `FusionInstanceCreated` (emituje go biblioteka), więc sygnaturę wzięto ze źródła repo i przyjęto dopiero po zgodności topicu: `0x9c0af8f1…e78f`.
5. **Testy** — `npm run vault:simulate:test` → 7/7, lista w [`runs.txt`](runs.txt).

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| Wykonuje dokładnie przygotowane calldata | symulator wysyła `plan.transaction.data` bez modyfikacji; test odwrotny (podmienione calldata) kończy się `reverted` | ✅ |
| Fork z przypiętym blokiem i właściwym callerem | `fork.blockNumber`/`blockHash` w raporcie; `from` z planu, impersonacja tylko na forku | ✅ |
| Jedna ścieżka EOA, inne jawnie bez wsparcia | test: caller z kodem → `UNSUPPORTED_EXECUTION_PATH` | ✅ |
| Raport podaje sukces/revert, gas, blok i hash planu | pola `status`, `result.succeeded`, `result.gasUsed`, `fork.blockNumber/blockHash`, `plan.sha256` | ✅ |
| Brak broadcastu | tylko lokalny `anvil`, `fork.broadcast: false`, brak klucza i `--broadcast` | ✅ |
| Brak automatycznej naprawy fabryki na forku | brak `anvil_setCode`, `upgradeToAndCall` i nadawania ról; jedyne mutacje to impersonacja i saldo callera | ✅ |

## Odstępstwa od planu

- Revert nie ma dekodowanego powodu: pole `revertReason` zostaje `null`, gdy
  provider nie zwraca danych rewertu. Dekodowanie własnych błędów fabryki
  (`cast 4byte-decode`) należy do T38 (troubleshooting).

## Follow-upy (poza zakresem, NIE zrobione)

- Raport symulacji nie ma schematu ani walidatora (jak plan z T28).
- Sprawdzenie stanu utworzonego vaulta jest w tym zadaniu ograniczone do zgodności
  eventu i return value — pełny verifier to T30.
- Ponowna symulacja pod inny blok niż `readBlock` planu jest dozwolona i tylko
  raportowana; polityka „plan wygasa" należy do preflightu (T39).

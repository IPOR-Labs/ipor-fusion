# T27 — Walidowana konfiguracja vaulta

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 przez Claude Code
- **Baza:** `562fea3`, branch `feature/agents-support`
- **Zależności:** T10 (`4433979`), T26 (ready-for-commit)

## Zakres wykonany

Wejście do utworzenia jednego vaulta ma schemat, przykład i walidator działający
bez RPC.

- `config/vaults/vault-creation.schema.json` — schemat wejścia: sieć i ID
  wdrożenia, wariant, caller, dane vaulta (nazwa, symbol, owner, underlying z
  `decimals`, `redemptionDelaySeconds`) i pakiet opłat z jawnym `expected`.
- `config/vaults/example.json` — poprawny przykład dla pilotażu (Ethereum,
  `permissionless-clone`, USDC, caller ≠ owner, pakiet 0 DAO).
- `tools/lib/vault-config.mjs` — wczytanie i sprawdzenie wejścia (schemat,
  adresy zerowe, rejestr, wariant), wspólne dla walidatora i kolejnych narzędzi.
- `tools/validate-vault-config.mjs` — `validate:vault-config`, tryb tekstowy i
  `--json`; kody `INVALID_CONFIG`, `UNKNOWN_DEPLOYMENT`, `UNVERIFIED_DEPLOYMENT`,
  `UNSUPPORTED_VARIANT`; wyjścia 0/1/2.
- `tools/lib/json-schema.mjs` — wspólny walker podzbioru JSON Schema, żeby nowe
  narzędzie nie kopiowało go po raz trzeci. Istniejące walidatory zostawiono bez
  zmian (refaktor byłby poza zakresem).
- `tools/test-validate-vault-config.mjs` — 17 testów `node --test`.
- `docs/vaults.md` (+ wyjątek w `.gitignore` i wpis w `docs/README.md`) — opis
  wejścia, jednostek, rozdziału caller/owner/signer i wspieranych wariantów.
- `package.json` — `validate:vault-config` i `validate:vault-config:test`.

## Kroki

1. **Semantyka wejścia z kodu** — `contracts/factory/FusionFactory.sol` (`clone` vs `cloneSupervised`) i `contracts/factory/lib/FusionFactoryLogicLib.sol` (`_validateAndGetDaoFeePackage` wybiera listę po `msg.sender`) → wariant i `packageSource` opisane po stronie wejścia, bez zgadywania stanu.
2. **Schemat + przykład** — `npm run validate:vault-config` → `valid vault creation configs: 1 checked`.
3. **Powiązanie z rejestrem** — walidator czyta `deployments/<chainId>/factories.json`, wymaga statusu `verified` i obecności operacji wariantu w `interface.supportedOperations`.
4. **Testy** — `npm run validate:vault-config:test` → 17/17 pass; lista odrzuceń w [`runs.txt`](runs.txt).
5. **Regresje sąsiednich walidatorów** — `npm run validate:deployments`, `npm run validate:test-suites` → pass.

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| Poprawny przykład przechodzi | `npm run validate:vault-config` | ✅ |
| Błędne jednostki odrzucone | testy: `"1 hour"`, `0.5` s, `0.05` bps, `"6"` decimals, 10001 bps | ✅ |
| Niepełny pakiet opłat odrzucony | test: brak `feeRecipient` → `missing required property` | ✅ |
| Niewspierany wariant odrzucony | test: `supervised-clone` → `UNSUPPORTED_VARIANT`; `create2-clone` → poza `enum` | ✅ |
| Brak ukrytych domyślnych odbiorców | `feeRecipient` wymagany, zero address odrzucony, `owner` wymagany i bez fallbacku na callera, nieznana właściwość to błąd | ✅ |
| Tylko wariant obsługiwany przez pilotaż | wariant musi być na liście `supportedOperations` wdrożenia; manifest listuje wyłącznie `clone(...)` | ✅ |

## Odstępstwa od planu

- Walidator wymaga statusu `verified` wdrożenia (`UNVERIFIED_DEPLOYMENT`).
  Plan wymaga tego wprost dopiero w T28, ale to polecenie operacyjne, a reguła
  z sekcji 9.1 zabrania opierania takich poleceń na wpisie `candidate`.
- `packageSource` jest deklaracją wejścia, nie rozstrzygnięciem: który zestaw
  pakietów obowiązuje dla danego callera, wie dopiero odczyt on-chain (T28).

## Follow-upy (poza zakresem, NIE zrobione)

- `tools/lib/affected-tests.mjs` nie zna nowych plików `tools/validate-vault-config.mjs`,
  `tools/lib/json-schema.mjs` ani `config/vaults/` — trafiają do kategorii
  „unknown" i rozszerzają wybór testów. Do uwzględnienia przy T45.
- `tools/validate-test-suites.mjs` i `tools/validate-deployments.mjs` nadal mają
  własne kopie walkera schematu; można je przenieść na `tools/lib/json-schema.mjs`
  w osobnym zadaniu porządkowym.

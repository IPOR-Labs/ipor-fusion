# T36 — Test pełnego cyklu środków i recepta

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 przez Claude Code
- **Baza:** `562fea3`, branch `feature/agents-support`
- **Zależności:** T32 (ready-for-commit), T35 (ready-for-commit)

## Zakres wykonany

- `test/deployed-factories/Erc4626StrategyLifecycleEthereum.t.sol` — jeden test
  `deployed-usage`: utworzenie vaulta przez niezmienioną fabrykę, konfiguracja
  rynku 100001 wdrożonymi fuse'ami, deposit → supply → exit → redeem z
  tolerancjami księgowymi.
- `config/test-suites.json` — nowa suita w grupie `deployed-factory`, z jawnie
  wymienionym finansowaniem testowym (`deal`) i przewijaniem czasu (`vm.warp`).
- `docs/recipes/erc4626-strategy.md` (+ indeks) — recepta całej ścieżki.
- Poprawki wykryte przez test: jednostka limitu rynku (WAD zamiast bps) w
  `config/strategies/*`, `tools/configure-strategy.mjs`, jego teście i
  `docs/vaults.md`; wdrożone ABI fuse'a w `catalog/fuses.json` i
  `docs/fuse-catalog.md`.

## Kroki

1. **Test cyklu** — `FOUNDRY_PROFILE=factory_ethereum forge test --match-path test/deployed-factories/Erc4626StrategyLifecycleEthereum.t.sol` → PASS, gas 2 864 956.
2. **Dwie realne usterki wykryte po drodze** — limit rynku w WAD oraz starsze ABI wdrożonego fuse'a; opis i dowody w [`runs.txt`](runs.txt).
3. **Katalog testów** — `npm run validate:test-suites` → 9 suit; `npm run test:fork -- --chain 1 --suite deployed-factory --block 25937526` → 2 suity, 2 testy.
4. **Spójność katalogu integracji** — `npm run validate:catalog`, `npm run catalog:check`.
5. **Regresja T35** — `npm run vault:configure:test` → 3/3 z odczytem limitu `500000000000000000`.

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| Jeden scenariusz deposit → operacja strategii → wyjście → withdraw/redeem | test przechodzi całą sekwencję w jednym przebiegu | ✅ |
| `docs/recipes/erc4626-strategy.md` | recepta z konfiguracją, rolami, pułapką ABI i uruchomieniem testu | ✅ |
| Sprawdzone salda i tolerancje księgowe | `assertApproxEqAbs` z tolerancją 1 USDC na 100 000 na wejściu, po operacji, po wyjściu i po redeem; salda idle sprawdzane dokładnie | ✅ |
| Respektowane role i opóźnienia | `execute` tylko jako ALPHA_ROLE, deposit jako adres z WHITELIST_ROLE, redeem dopiero po redemption delay | ✅ |
| Pomocnicze finansowanie i przyspieszanie czasu oznaczone jako testowe | komentarze w teście oraz `setUp.mutations` w katalogu suit | ✅ |

## Odstępstwa od planu

- Ścieżka wyjścia to `redeem` na vaulcie, bez `WithdrawManager.request`:
  pilotażowy vault nie ma skonfigurowanych instant-withdraw fuse'ów ani opłat za
  żądanie, więc żądanie nie jest wymagane. Ścieżka `request/redeemFromRequest`
  potrzebuje osobnej konfiguracji i osobnego testu.
- Test nie pokazuje zysku: fork stoi na jednym bloku, więc wejście i wyjście
  następują po tej samej cenie udziału.

## Follow-upy (poza zakresem, NIE zrobione)

- Wdrożony fuse ERC4626 nie ma ograniczeń poślizgu, które ma bieżące źródło.
  Decyzja, czy pilotaż ma używać wdrożonej starszej wersji, czy wdrożyć nową,
  należy do zespołu.
- Warto dodać test ścieżki `request` → `redeemFromRequest` po skonfigurowaniu
  instant-withdraw fuses.
- `vault:configure` nie ustawia `WHITELIST_ROLE` ani nie przełącza vaulta w tryb
  publiczny; robi to test. Jeśli ma to być część konfiguracji, to osobne zadanie.

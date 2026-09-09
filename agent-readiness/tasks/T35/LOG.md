# T35 — Plan konfiguracji jednej strategii ERC4626

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 przez Claude Code
- **Baza:** `562fea3`, branch `feature/agents-support`
- **Zależności:** T10 (`4433979`), T30 (ready-for-commit), T33 (ready-for-commit)

## Zakres wykonany

- `config/strategies/strategy-configuration.schema.json` i
  `config/strategies/erc4626-usdc.json` — wejście: wpis katalogu, czterej
  operatorzy, limit rynku w bps, dozwolone vaulty ERC4626 jako substrates i
  aktywa do wyceny.
- `tools/configure-strategy.mjs` (`vault:configure`) — cztery kroki wykonywane
  przez właściwych operatorów, `--dry-run` z samym calldata, odczyt konfiguracji
  z vaulta na końcu i nazwane odmowy.
- `tools/test-configure-strategy.mjs` — 3 testy, w tym pełny scenariusz na forku.
- `docs/vaults.md` — sekcja „Configuring the ERC4626 pilot strategy" z tabelą
  kroków i tabelą błędów.
- `package.json` — `vault:configure`, `vault:configure:test`.

## Kroki

1. **Ustalenie ścieżki konfiguracji z kodu** — `PlasmaVaultGovernance.addFuses/addBalanceFuse/grantMarketSubstrates/setupMarketsLimits/activateMarketsLimits` oraz `IporFusionAccessManager.grantRole`; role z `docs/roles-and-permissions.md`.
2. **Ręczna próba na forku** — cała sekwencja wykonana przez `cast send` na anvilu, żeby potwierdzić kolejność i kształt argumentów (`runs.txt`).
3. **Ponowne użycie zweryfikowanych wdrożeń** — adresy fuse'ów pochodzą wyłącznie z katalogu (T33) i muszą mieć status `observed`, inaczej `UNVERIFIED_FUSE`.
4. **Wycena** — narzędzie sprawdza, czy price manager vaulta wycenia wskazane aktywa; dla USDC źródło już istnieje, więc pilotaż nie dodaje feedu.
5. **Testy** — `npm run vault:configure:test` → 3/3.

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| Konfiguruje role, feeds, fuse'y, balance fuse'y, substrates i limity | cztery kroki + kontrola wyceny; feed nie jest dodawany, bo wymagane źródło już istnieje (jawnie sprawdzone) | ✅ |
| Wyłącznie ta integracja | wejście wskazuje jeden `catalogId`; brak obsługi innych protokołów, market i chain muszą się zgadzać z katalogiem | ✅ |
| Ponownie użyte zweryfikowane wdrożenia komponentów | adresy z `catalog/fuses.json`, wymagany status `observed` | ✅ |
| Na forku właściwi operatorzy konfigurują vault | test: `status configured`, `verification.ok`, odczyt `getFuses`/`getMarketSubstrates`/`getMarketLimit` z vaulta | ✅ |
| Brak roli daje czytelny błąd | test: `MISSING_ROLE: … does not hold OWNER_ROLE (1), required for step "grant-roles"` | ✅ |
| Błędna konfiguracja daje czytelny błąd | testy: `SUBSTRATE_ASSET_MISMATCH`, `UNKNOWN_INTEGRATION`, `MARKET_MISMATCH`, `INVALID_ARGUMENT` | ✅ |

## Odstępstwa od planu

- Narzędzie działa wyłącznie na forku: brak wsparcia dla impersonacji to
  `NOT_A_FORK`. Wersja podpisująca transakcje należy do ścieżki wykonawczej
  (T39–T42), nie tutaj.
- Kroku „feeds" nie ma jako operacji zapisu, bo dla pilotażu nie jest potrzebny.
  Jest za to kontrola: brak źródła ceny to `PRICE_SOURCE_MISSING` przed
  jakąkolwiek zmianą.

## Follow-upy (poza zakresem, NIE zrobione)

- Vault pozostaje prywatny: `convertToPublicVault` albo `WHITELIST_ROLE` dla
  deponujących należy do scenariusza cyklu środków (T36).
- Instant withdraw fuses (`CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE`) nie są
  konfigurowane; ścieżka wypłaty pilotażu opiera się na saldzie vaulta i wyjściu
  ze strategii — do rozstrzygnięcia w T36.
- Wdrożony balance fuse jest starszą wersją niż źródło w repo (T33); test cyklu
  środków musi to potwierdzić w praktyce.

# T10 — Mapa ról i wywołujących

- **Status:** ready-for-commit
- **Data:** 2026-09-08 (Europe/Warsaw)
- **Agent/model:** Codex GPT-5
- **Baza:** `git rev-parse --short HEAD` = `1ea8233`, branch `feature/agents-support`
- **Zależność:** T09 (`1ea8233`)

## Zakres wykonany

Dodano mapę bieżącego modelu dostępu fabryki i vaulta. Dokument rozdziela bezpośredniego
callera fabryki, argument `owner_`, administratora fabryki, `ADMIN_ROLE` vaulta oraz
efektywnego callera wyznaczanego przez ContextManager. Opisuje też wybór pakietu opłat,
hierarchię administratorów ról, role techniczne oraz rozdziela execution delay od redemption
delay.

| Plik                                           | Opis                                                       |
| ---------------------------------------------- | ---------------------------------------------------------- |
| `docs/roles-and-permissions.md`                | Nowa mapa ról, callerów, administratorów i opóźnień.       |
| `docs/README.md`                               | Wpis w indeksie i przykład selektywnego wersjonowania.     |
| `.gitignore`                                   | Wąski wyjątek dla nowego dokumentu.                        |
| `agent-readiness/PLAN.md`                      | Checkbox T10 zmieniony na `[x]`.                           |
| `agent-readiness/STATUS.md`                    | T09 uzgodnione z Git; T10 ustawione na `ready-for-commit`. |
| `agent-readiness/tasks/T10/LOG.md`             | Przebieg i wyniki weryfikacji.                             |
| `agent-readiness/tasks/T10/COMMIT.md`          | Instrukcja ręcznego commita.                               |
| `agent-readiness/tasks/T10/commit-message.txt` | Gotowy pełny komunikat commita.                            |

## Źródła sprawdzone bezpośrednio

1. `FusionFactory.sol` i `FusionFactoryAccessControl.sol`: wszystkie bieżące `onlyRole`,
   publiczny `clone`, chroniony `cloneSupervised`, inicjalny admin i autoryzacja upgrade'u.
2. `FusionFactoryLib.sol` i `FusionFactoryLogicLib.sol`: zachowany `msg.sender`, walidacja
   `owner_`, wybór custom/global fee package, `withAdmin_`, finalne przypisania kont.
3. `AccessManagerFactory.sol`, `IporFusionAccessManager.sol` i biblioteki access: tymczasowy
   admin fabryki, jego odwołanie, granty, minimalne execution delays, schedule consumption i
   redemption lock.
4. `Roles.sol` i `IporFusionAccessManagerInitializerLibV1.sol`: wszystkie role, jawna
   hierarchia administratorów, role-to-selector i account-to-role dla tworzonego vaulta.
5. `PlasmaVault.sol`, `PlasmaVaultGovernance.sol`, `ContextManager.sol` i storage kontekstu:
   rozstrzyganie efektywnego callera oraz dodatkowe kontrole receivera/ownera.
6. Przypięte źródło OpenZeppelin `5.0.2` w `node_modules` oraz lockfile: domyślna rola admina,
   zarządzanie rolami i dokładny model schedule/execute/cancel.
7. `FusionFactoryBusinessClientFeePackagesTest.t.sol` i `FusionFactory.t.sol`: rozdzielenie
   business caller / regular caller / maintenance caller / `owner_` i wynikowe granty.

## Weryfikacja

1. Checker linków przeszedł po `docs/README.md` i `docs/roles-and-permissions.md`: 36
   relatywnych linków, zero brakujących celów.
2. Checker treści porównał stałe z `Roles.sol` z nowym dokumentem: wszystkie 25 nazw ról
   występuje w mapie. Osobne wyszukanie wszystkich `onlyRole` w `FusionFactory.sol`
   potwierdziło opisany zakres trzech aktywnych ról i publicznego `clone`.
3. `git check-ignore --no-index` potwierdził, że `docs/roles-and-permissions.md` jest
   selektywnie odblokowany, a przykładowy `docs/t10-private-scratch.md` nadal pasuje do
   ogólnej reguły `docs/*`.
4. Prettier zaakceptował nowy dokument, indeks i artefakty T10. Pełne PLAN i STATUS mają
   zastany drift formatowania tabel — te same wersje z `HEAD` również nie przechodzą
   Prettiera — więc nie przeformatowano całych plików i nie dodano ubocznego churnu.
5. `forge test --match-path test/factory/FusionFactoryBusinessClientFeePackagesTest.t.sol`:
   18 passed, 0 failed, 0 skipped. Testy obejmują wybór custom/global package według callera
   oraz `cloneSupervised`.
6. `forge test --match-path test/factory/FusionFactory.t.sol`: 66 passed, 0 failed,
   0 skipped. Testy obejmują owner/admin, techniczne role, autoryzację upgrade'u oraz
   redemption delay.
7. `npm run format:check` zakończyło się kodem 1 na 301 zastanych plikach Solidity (w tym
   źródłach i testach tylko odczytanych w T10). Żaden plik Solidity nie został zmieniony ani
   automatycznie sformatowany.
8. Kontrola whitespace dla wszystkich ośmiu plików T10 oraz `git diff --check` dla zmian
   śledzonych przeszły bez błędów.

## Odstępstwa od planu

Brak. Dokument nie deklaruje żadnych wdrożonych adresów ani aktualnych posiadaczy ról.

## Follow-upy (poza zakresem, NIE zrobione)

- T11 doda instrukcje pracy nad fabrykami.
- Weryfikacja wdrożeń, adresów i bieżących posiadaczy ról pozostaje zadaniem wymagającym
  osobnych dowodów on-chain.

## Blokada (tylko gdy status = blocked/partial)

Nie dotyczy.

# T11 — Instrukcje pracy nad fabrykami

- **Status:** ready-for-commit
- **Data:** 2026-09-08 (Europe/Warsaw)
- **Agent/model:** Codex GPT-5
- **Baza:** `git rev-parse --short HEAD` = `4433979`, branch `feature/agents-support`
- **Zależności:** T08 (`f3b624f`), T10 (`4433979`)

## Zakres wykonany

Dodano instrukcje katalogowe dla `contracts/factory/` oraz krótki przewodnik po wyborze
factory, pełnym flow tworzenia vaulta, znaczeniu aktywnej wersji i doborze testów. Dokumenty
wskazują `FeeManagerFactory` spoza katalogu factory i rozróżniają świeże wdrożenie lokalne,
świeże wdrożenie na forku, upgrade istniejącego proxy na forku oraz użycie istniejącej
fabryki bez mutacji.

| Plik                                           | Opis                                                       |
| ---------------------------------------------- | ---------------------------------------------------------- |
| `contracts/factory/AGENTS.md`                  | Lokalne reguły nawigacji, zmian i doboru testów.           |
| `docs/factories.md`                            | Przewodnik po factory, wersjach i czterech trybach testów. |
| `docs/README.md`                               | Link do przewodnika i przykład selektywnego wyjątku.       |
| `.gitignore`                                   | Wąski wyjątek dla `docs/factories.md`.                     |
| `agent-readiness/PLAN.md`                      | Checkbox T11 zmieniony na `[x]`.                           |
| `agent-readiness/STATUS.md`                    | T10 uzgodnione z Git; T11 ustawione na `ready-for-commit`. |
| `agent-readiness/tasks/T11/LOG.md`             | Przebieg i wyniki weryfikacji.                             |
| `agent-readiness/tasks/T11/COMMIT.md`          | Instrukcja ręcznego commita.                               |
| `agent-readiness/tasks/T11/commit-message.txt` | Gotowy pełny komunikat commita.                            |

## Źródła sprawdzone bezpośrednio

1. Wszystkie kontrakty w `contracts/factory/`, ich entry pointy `create`/`clone`, wzorce
   UUPS/Ownable/permissionless oraz odpowiadające testy wyszukane po nazwie.
2. `FusionFactory`, biblioteki logic/storage i siedem adresów component factories używanych
   w pełnym flow.
3. `PlasmaVault.proxyInitialize` i `contracts/managers/fee/FeeManagerFactory.sol` dla
   rzeczywistego miejsca wdrożenia FeeManagera.
4. `FusionFactory.t.sol` dla czystego lokalnego setupu bez RPC.
5. Oba `FusionFactory*ForkTest` dla świeżych factory wdrażanych na forku i kopiowania
   wybranej konfiguracji z istniejącego adresu.
6. `FusionFactoryDaoFeePackagesHelper` oraz jego callery dla upgrade'u proxy, grantów ról i
   podmiany factory/base addresses w fixture forkowym.
7. PLAN T20–T25 dla potwierdzenia, że rejestr wdrożeń, matching ABI, inspekcja i test
   niezmienionej istniejącej fabryki są dalszymi zadaniami, a nie gotowymi artefaktami.

## Weryfikacja

Do uzupełnienia po kontrolach końcowych.

## Odstępstwa od planu

Brak. T11 dokumentuje brak dedykowanego testu niezmienionej istniejącej fabryki zamiast
pozorować ten tryb przy użyciu fixture'u, który wykonuje upgrade.

## Follow-upy (poza zakresem, NIE zrobione)

- T12 doda instrukcje katalogowe dla fuse'ów.
- T20–T25 dodadzą źródło wdrożeń, schemat/ABI/manifest, inspekcję i test niezmienionej
  fabryki.

## Blokada (tylko gdy status = blocked/partial)

Nie dotyczy.

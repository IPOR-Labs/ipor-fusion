# T13 — Katalog testów dla pilotażu fabryki

- **Status:** ready-for-commit
- **Data:** 2026-09-08 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 (1M context) przez Claude Code
- **Baza:** `git rev-parse --short HEAD` = `4771509`, branch `feature/agents-support`
- **Zależności:** T04 (committed `7364631`), T11 (committed `a92080a`)

## Zakres wykonany

Powstał maszynowy katalog testów pilotażu fabryki wraz ze schematem, walidatorem, instrukcją
scoped dla katalogu testów i początkiem dokumentu `docs/testing.md`. Sklasyfikowano wyłącznie
7 suit z najwyższego poziomu `test/factory/`; cała reszta `test/` (w tym `test/factory/price_feed/`)
jest jawnie oznaczona jako niesklasyfikowana, z wprost zapisaną regułą, że brak wpisu nie jest
dowodem w żadną stronę.

| Plik                             | Zmiana                                                                             |
| -------------------------------- | ---------------------------------------------------------------------------------- |
| `config/test-suites.json`        | nowy — 7 sklasyfikowanych suit + blok `scope` z zakresem i wyłączeniem             |
| `config/test-suites.schema.json` | nowy — JSON Schema 2020-12 formatu katalogu                                        |
| `tools/validate-test-suites.mjs` | nowy — walidator bez zależności (podzbiór JSON Schema + kontrole krzyżowe)         |
| `package.json`                   | nowy skrypt `validate:test-suites`                                                 |
| `test/AGENTS.md`                 | nowy — instrukcje scoped dla `test/`                                               |
| `docs/testing.md`                | nowy — dobór suity, cztery typy fixture'ów, providery/profile/FFI, czytanie awarii |
| `docs/README.md`                 | wpis w indeksie + linia wyjątku w bloku `.gitignore`                               |
| `.gitignore`                     | `!docs/testing.md`                                                                 |

## Kroki

1. **Uzgodnienie stanu z Git** — `git log -3 --format='%h %s'` → T12 zacommitowane jako `4771509`, drzewo czyste. STATUS.md: T12 `ready-for-commit` → `committed 4771509`.
2. **Odczyt zakresu** — PLAN.md sekcja 7 (trzy rodzaje fixture'ów, kryterium odbioru) i blok `#### T13`; `contracts/factory/AGENTS.md` z T11 dla nazewnictwa trybów testów.
3. **Inwentaryzacja suit pilotażu** — `ls test/factory/` → 7 plików `.t.sol` na najwyższym poziomie + podkatalog `price_feed/` (zostawiony niesklasyfikowany, należy do T49).
4. **Ustalenie RPC/bloku/FFI dla każdej suity** — `grep -n "createSelectFork\|envString\|vm.ffi"` po plikach → tylko dwie suity forkują (`ETHEREUM_PROVIDER_URL`, obie `FORK_BLOCK = 23831825`); `grep -rn "vm\.ffi" test/` → **zero** trafień w całym `test/`, mimo że `foundry.toml` ustawia `ffi = true` globalnie. Pole `ffi` w katalogu zapisuje więc faktyczne użycie, nie dostępność.
5. **Empiryczne potwierdzenie, że suity lokalne nie potrzebują RPC** — każda z 5 uruchomiona z providerami wskazującymi na `http://127.0.0.1:1` → wszystkie przeszły (66 + 18 + 3 + 21 + 21 = 129). To sprawdzenie zachowania, nie tylko odczyt kodu.
6. **Analiza helperów w `setUp()`** — przeczytane ciała `setUp()` wszystkich 7 suit. Ustalenia zapisane w polach `setUp.deploys/mutations/externalAddresses/helpers`. Najważniejsze: obie suity forkowe **deployują własną** `FusionFactory` (nowa implementacja + nowy `ERC1967Proxy`), własne `PlasmaVaultFactory`, `FeeManagerFactory`, `PlasmaVaultBase` i nowy `plasmaVaultCoreBase`, a istniejący proxy mainnetowy `0xcd05909C…` tylko **czytają** jako źródło konfiguracji; dodatkowo prankują posiadacza USDC, by sfinansować konta testowe. Komentarz w kodzie podaje powód: wdrożone komponenty nie przyjmują obecnego kształtu `PlasmaVaultInitData`.
7. **Wniosek klasyfikacyjny** — żadna z 7 suit nie jest typu `deployed-usage`. Obie „forkowe" to `fork-fresh-deployment`. Zapisane wprost w `doesNotProve` obu wpisów, w `test/AGENTS.md` i w `docs/testing.md` — to dokładnie pułapka z sekcji 2 planu.
8. **Schemat** — `config/test-suites.schema.json`, draft 2020-12, `additionalProperties: false` na każdym poziomie, enum czterech typów fixture'a zgodny z czterema trybami z `contracts/factory/AGENTS.md` (T11), `rpc` z wzorcem `^[A-Z0-9_]+_PROVIDER_URL$` (nazwa zmiennej, nigdy URL).
9. **Walidator** — `tools/validate-test-suites.mjs`, bez nowych zależności npm; interpretuje podzbiór schematu faktycznie użyty w pliku (`type`, `required`, `enum`, `pattern`, `minLength`, `minimum`, `minItems`, `items`, `additionalProperties`, `$ref`) plus kontrole, których schemat nie wyraża: unikalność `id`, istnienie `path` w checkoutcie, wymóg RPC+bloku dla fixture'ów forkowych i zakaz obu dla `local-deployment`.
10. **Walidacja pozytywna** — `npm run validate:test-suites` → `valid: config/test-suites.json (7 suite(s) classified)`, exit 0. Wyjście: `runs.txt`.
11. **Walidacja negatywna (8 przypadków)** — każdy zepsuty wariant katalogu przepuszczony przez walidator, każdy `exit=1` z nazwaną przyczyną i wskazanym wpisem. Pełne wyjście: `validator-negative.txt`. Przypadki: nieznana wartość `fixture`; URL RPC zamiast nazwy zmiennej; suita forkowa bez `block`; nieistniejąca `path`; zduplikowane `id`; brak wymaganego pola; suita lokalna deklarująca RPC; literówka w nazwie pola.
12. **Uruchomienie suit forkowych** — `forge test --match-path` dla obu → 8 passed i 2 passed, 0 failed. Wyjście: `runs.txt`.
13. **Kontrola linków** — wszystkie ścieżki relatywne z `docs/testing.md` (9), `test/AGENTS.md` (2) i `docs/README.md` (10) przepuszczone przez `[ -e ]` → 0 broken.
14. **Kontrola komend z dokumentu** — każda komenda wypisana w `docs/testing.md` uruchomiona: `forge build`, 5 komend lokalnych, 2 forkowe, `npm run validate:test-suites`. Liczby w dokumencie (129 lokalnych, 10 forkowych, blok 23831825) pochodzą z tych przebiegów.
15. **Formatowanie** — `prettier --check` na wszystkich nowych/zmienionych plikach → czysto (pliki sformatowane przez `prettier --write` wyłącznie w obrębie tego zadania). `npm run format:check` raportuje 301 plików `.sol` — to zastane odchylenie, żaden `.sol` nie był ruszany.
16. **Kontrola diffu** — `git status --short` → 3 zmienione (`.gitignore`, `docs/README.md`, `package.json`) i 4 nowe ścieżki; `git status --short | grep -c '\.sol'` → `0`.

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md)                             | Sprawdzenie (komenda)                                                                                                                                                               | Wynik                |
| ------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------- | --- |
| Powstaje `config/test-suites.json` i jego schemat | `node tools/validate-test-suites.mjs` → `valid … (7 suite(s) classified)`                                                                                                           | ✅                   |
| Powstaje `test/AGENTS.md`                         | `[ -e test/AGENTS.md ]`                                                                                                                                                             | ✅                   |
| Powstaje początek `docs/testing.md`               | `[ -e docs/testing.md ]` + wyjątek w `.gitignore` + wpis w `docs/README.md`                                                                                                         | ✅                   |
| Sklasyfikowane wyłącznie testy pilotażu fabryki   | 7 wpisów, wszystkie `test/factory/*.t.sol` z najwyższego poziomu                                                                                                                    | ✅                   |
| Reszta pozostaje **jawnie** niesklasyfikowana     | pole `scope.unclassified` + sekcja „What is not classified" w `docs/testing.md` + akapit w `test/AGENTS.md`                                                                         | ✅                   |
| Wpisy określają **RPC**                           | 5 × `null`, 2 × `ETHEREUM_PROVIDER_URL`; potwierdzone przebiegiem z nieosiągalnym providerem                                                                                        | ✅                   |
| Wpisy określają **blok**                          | 5 × `null`, 2 × `23831825`; odczytane z `FORK_BLOCK` w obu plikach                                                                                                                  | ✅                   |
| Wpisy określają **profil**                        | 7 × `default`; `foundry.toml` ma tylko `default` i `arbitrum`                                                                                                                       | ✅                   |
| Wpisy określają **FFI**                           | 7 × `false`; `grep -rn "vm\.ffi" test/` → 0 trafień                                                                                                                                 | ✅                   |
| Wpisy określają **typ fixture'a**                 | 5 × `local-deployment`, 2 × `fork-fresh-deployment`, 0 × `deployed-usage`                                                                                                           | ✅                   |
| **Sprawdzone również helpery w `setUp()`**        | ciała `setUp()` i metody `_copyBaseAddresses`/`_copyOtherConfiguration`/`_setupDaoFeePackages`/`_setupBusinessClientFeePackages` przeczytane i opisane w polu `setUp` każdego wpisu | ✅                   |
| **Błędny wpis nie przechodzi walidacji**          | 8 zepsutych wariantów, każdy `exit=1` z nazwaną przyczyną — `validator-negative.txt`                                                                                                | ✅                   |
| Suity nadal przechodzą                            | 129 lokalnych + 10 forkowych, 0 failed — `runs.txt`                                                                                                                                 | ✅                   |
| Brak sekretów                                     | katalog i dokumenty podają wyłącznie nazwy zmiennych; schemat wymusza wzorzec `^[A-Z0-9_]+_PROVIDER_URL$`                                                                           | ✅                   |
| Brak przypadkowego formatowania                   | `git status --short                                                                                                                                                                 | grep -c '\.sol'`→`0` | ✅  |

## Odstępstwa od planu

`test/factory/price_feed/` celowo pozostawiony niesklasyfikowany — należy do pilotażu price feedu
(T49), a nie do pilotażu fabryki, a zakres T13 mówi wprost o wyłącznie potrzebnych suitach.

Skrypt `validate:test-suites` i sam walidator nie są wymienione w **Zakres** wprost, ale **Odbiór**
wymaga, żeby błędny wpis nie przeszedł walidacji — bez wykonywalnego walidatora tego kryterium nie da
się sprawdzić. Walidator jest celowo minimalny, dotyczy tylko tego jednego pliku i nie dodaje
zależności npm; walidator manifestów wdrożeń pozostaje osobnym zadaniem (T21).

## Follow-upy (poza zakresem, NIE zrobione)

- Żadna suita w repo nie ma typu `deployed-usage`, więc dziś **nic nie dowodzi**, że wdrożona
  fabryka `0xcd05909C…` potrafi utworzyć vault. To jest dokładnie treść T25 i warto, żeby T25
  dodał pierwszy taki wpis do katalogu.
- Pole `tests` w katalogu może się rozjechać z kodem przy dodaniu testu. Kandydat na kontrolę
  w CI przy T45 (kontrola aktualności artefaktów).
- `npm run format:check` raportuje 301 plików `.sol` z zastanym odchyleniem formatowania. Zastane
  od T05, nadal nietknięte — osobna decyzja Pete'a, czy i kiedy je wyrównać.
- Nazewnictwo katalogów `test/` vs `contracts/` jest niespójne (`velodrome` vs
  `velodrome_superchain`, `markl` vs `merkl`); zgłoszone już przy T12, istotne dla T19.

# Plan przygotowania IPOR Fusion do pracy agentów AI/LLM

Data: 2026-09-07. Punkt odniesienia: lokalny checkout, commit `6e1fd02`.

Tryb realizacji: **jedno zadanie z sekcji 9 → weryfikacja → jeden commit → wybór kolejnego zadania**. Sekcje 1–8 opisują rozwiązanie docelowe; sekcja 9 jest listą pracy, a sekcja 10 definiuje pomiar efektów.

## 1. Cel i rekomendowana kolejność

Agent powinien umieć samodzielnie znaleźć właściwe kontrakty, odtworzyć problem, przygotować poprawkę, uruchomić odpowiednie testy oraz przygotować użycie wdrożonej fabryki na wskazanej sieci. Wynik jego pracy ma być sprawdzalny przez człowieka i CI.

Rekomendowana kolejność: **powtarzalne środowisko i mapa repo → rejestr wdrożeń i ABI → test użycia istniejącej fabryki → narzędzia do konfiguracji vaulta → automatyczne utrzymanie i pomiar skuteczności agentów**.

Pierwszą demonstracją powinno być utworzenie vaulta przez istniejącą fabrykę na forku jednej sieci, sprawdzenie adresów i uprawnień oraz wykonanie małego scenariusza deposit/withdraw. Wybrać sieć po weryfikacji wdrożeń; Ethereum jest kandydatem ze względu na istniejące przykłady, ale nie zakładać z góry zgodności tamtejszej fabryki z bieżącym kodem.

Ten dokument jest planem implementacji. Proponowane katalogi, polecenia i narzędzia nie zostały w ramach tego zadania utworzone. Nie uruchamiano testów kontraktów, nie sprawdzano stanu sieci przez RPC i nie wysyłano transakcji. Przegląd obejmował kod, konfigurację i reprezentatywne testy; nie jest pełnym audytem repozytorium ani wdrożeń.

Aktualizacja po konfiguracji pamięci: współdzielenie pamięci Claude/Codex i dostęp do Obsidiana zostały już wdrożone w konfiguracji użytkownika na tej maszynie, poza repo. Nie są zadaniami do ponownego wykonania ani plikami do commitowania tutaj. Repozytorium powinno działać również dla agenta bez tej prywatnej pamięci; instrukcje repo mają zawierać potrzebne zasady projektowe, bez kopiowania prywatnych notatek i historii rozmów.

## 2. Co już jest i co utrudnia pracę

| Obserwacja w repo | Znaczenie dla agenta | Działanie |
| --- | --- | --- |
| [README.md](../README.md) opisuje instalację i testy, ale nie prowadzi przez architekturę ani użycie fabryki. | Agent musi odtwarzać ścieżkę pracy z kodu. | Dodać krótki start i odnośniki do przewodników zadaniowych. |
| [.gitignore](../.gitignore) ignoruje m.in. `docs/`, `CLAUDE.md`, `GEMINI.md`, `.claude/` i `ai_context`. Brak śledzonego `AGENTS.md`. | Lokalna wiedza może nie trafić do checkoutu innego agenta. | Wersjonować wybrane wspólne instrukcje; zachować ignorowanie prywatnych notatek i ustawień. |
| README wskazuje `.env.example`, którego nie ma w checkoutcie; `coverage:file` wskazuje nieobecny `tools/check_coverage.sh`. | Pierwsze kroki i część poleceń nie są kompletne. | Uzupełnić brakujące elementy lub usunąć nieaktualne odwołania. |
| [foundry.toml](../foundry.toml) przypina Solidity 0.8.30, ustawia Cancun, profil Arbitrum na Paris, `ffi = true` i zapis/odczyt całego katalogu projektu. | Potrzebna jest jawna mapa profili i zależności testów od FFI. | Udokumentować dobór profilu i zawęzić uprawnienia tam, gdzie testy ich nie potrzebują. |
| [CI](../.github/workflows/smart-contracts-build.yml) używa Foundry `stable`, `npm install` i `FOUNDRY_PROFILE=ci`, ale brak jawnego `[profile.ci]`. | Środowisko nie jest w pełni przypięte, a intencja profilu CI pozostaje niejasna. | Przypiąć sprawdzony toolchain, używać lockfile i zdefiniować profile. |
| CI uruchamia `prettier:all`, które używa `--write`; pre-commit ma inne wersje Prettier i pluginu niż `package.json`. | Formatowanie może zależeć od ścieżki uruchomienia; CI nie ma jawnego kroku kontroli formatowania bez zapisu. | Ujednolicić wersje i dodać skrypt `--check`. |
| Repo ma rozbudowane `contracts/`, `test/`, helpery i opisy integracji, np. [architekturę vaultów](../contracts/vaults/README.md). | Jest na czym zbudować nawigację bez przepisywania wszystkiego. | Indeksować i weryfikować istniejące materiały. |
| Testy odwołują się do Ethereum, Arbitrum, Base, TAC i Ink; część forków ma stały blok, część korzysta z bieżącego stanu. | Brak RPC lub zmiana stanu sieci może wyglądać jak błąd kodu. | Rozdzielić testy lokalne, regresje na stałych blokach i testy bieżących wdrożeń. |
| Brak śledzonego centralnego `deployments/` i katalogu `script/`; `contracts/deploy/initialization/` zawiera typy metadanych. | Same typy i adresy w testach nie wystarczają do wyboru fabryki. | Dodać rejestr oraz wykonywalne scenariusze użycia. |

### Najważniejsza pułapka: test na forku nie musi testować obecnego wdrożenia

[FusionFactoryDaoFeePackagesForkTest](../test/factory/FusionFactoryDaoFeePackagesForkTest.t.sol) oraz [FusionFactoryBusinessClientFeePackagesForkTest](../test/factory/FusionFactoryBusinessClientFeePackagesForkTest.t.sol) odczytują konfigurację istniejącej fabryki, ale wdrażają nową fabrykę i zastępują część komponentów. Podobnie [TestConfigurationExample](../test/TestConfigurationExample.t.sol) tworzy świeżą fabrykę.

Ponadto [FusionFactoryDaoFeePackagesHelper](../test/test_helpers/FusionFactoryDaoFeePackagesHelper.sol) wykonuje na forku upgrade implementacji, podmienia fabryki i konfigurację oraz nadaje role. To przydatne do testowania nowego kodu, ale sukces takiego testu nie dowodzi, że użytkownik może wykonać identyczne wywołanie na niezmienionym wdrożeniu.

Adres `0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852` i blok `23831825` występują jako referencja Ethereum w tych testach. Traktować je jako dane do weryfikacji historycznej, a nie potwierdzony adres produkcyjny na dzień wykonania planu.

## 3. Warstwa instrukcji i wiedzy o kodzie

### 3.1. Jeden krótki punkt wejścia

Utworzyć główny `AGENTS.md`, docelowo około 100–150 linii. Powinien zawierać:

- Cel projektu i mapę głównych katalogów z odnośnikami.
- Sprawdzone polecenia instalacji, kompilacji, lokalnych testów i testów na forku.
- Regułę doboru testów do zmienianego modułu oraz oczekiwaną zawartość opisu poprawki.
- Zasady Solidity: storage współdzielony przez `delegatecall`, inicjalizacja, role, jednostki, rounding, zgodność ABI i upgrade'ów.
- Informację, gdzie znaleźć rejestr wdrożeń, ABI, konfiguracje i procedury użycia fabryk.
- Regułę interpretacji dowodów: lokalne testy potwierdzają lokalny kod; rejestr wskazuje zatwierdzone wdrożenia; odczyt on-chain potwierdza stan na konkretnym bloku. Rozbieżność wymaga wyjaśnienia.
- Zasady pracy z lokalnymi zmianami użytkownika, sekretami i uzgodnionym zakresem operacji on-chain.
- Pomijanie `node_modules/`, `lib/`, `out/`, `cache/` przy pierwszym wyszukiwaniu, chyba że zadanie dotyczy zależności lub artefaktów.

Instrukcje specyficzne dla fabryk, fuse'ów i testów umieścić odpowiednio w `contracts/factory/AGENTS.md`, `contracts/fuses/AGENTS.md` i `test/AGENTS.md`. W katalogu fabryk koniecznie wskazać również `contracts/managers/fee/FeeManagerFactory.sol`, który leży poza tym katalogiem.

Dokumentację techniczną dla zespołu i agentów proponuję prowadzić po angielsku; ten plan pozostaje po polsku. Adaptery instrukcji dla poszczególnych narzędzi powinny wskazywać wspólne źródło, zamiast zawierać rozbieżne kopie zasad. Faktyczny sposób ładowania instrukcji sprawdzić dla używanych klientów.

### 3.2. Dokumenty odpowiadające na konkretne pytania

| Proponowany plik | Pytania, na które odpowiada |
| --- | --- |
| `docs/architecture.md` | Jak współpracują PlasmaVault, Base, widoki ERC4626, pluginy, governance, managery, fuse'y i oracle? Który adres ma storage i kto jest `msg.sender`? |
| `docs/testing.md` | Które testy uruchomić, jaki RPC/profil/blok wybrać i jak odróżnić błąd infrastruktury od regresji? |
| `docs/invariants.md` | Jakie własności muszą zachować księgowanie, opłaty, wyceny, wypłaty i kontrola dostępu? Gdzie są testy każdej własności? |
| `docs/factories.md` | Której fabryki użyć do całego vaulta, wrappera lub price feedu? Jakie ma wersje, zależności i wymagania? |
| `docs/roles-and-permissions.md` | Kto tworzy vault, kto zostaje właścicielem, kto konfiguruje fuse'y, kto wykonuje strategię, jakie są opóźnienia? |
| `docs/troubleshooting.md` | Jak diagnozować revert, brak oracle, zły substrate, niezgodne ABI, brak roli lub brak historycznego stanu RPC? |
| `docs/recipes/` | Jak wykonać jedno konkretne zadanie od wejścia do sprawdzonego wyniku? |

Dokument architektury powinien odsyłać do istniejącego opisu w `contracts/vaults/README.md`, a przykłady i diagramy porównać z implementacją. Przy niezmiennikach rozróżnić własność już testowaną od postulowanej; opisać zaokrąglenia i tolerancje zamiast zakładać proste równości ERC4626.

Dodać katalog maszynowy `catalog/fuses.json`: nazwa, źródło, typ, market ID, format substrates, struktury enter/exit, wymagane role, balance fuse, zależności oracle, testy i odnośniki do zweryfikowanych wdrożeń. Wykorzystać istniejące typy z `contracts/deploy/initialization/`. Dane strukturalne generować, znaczenie biznesowe uzupełniać ręcznie.

**Kryterium odbioru:** nowy agent znajduje właściwy kontrakt i minimalny zestaw testów dla trzech reprezentatywnych zadań, korzystając z instrukcji repo; każdy odnośnik do kodu prowadzi do istniejącego pliku.

## 4. Powtarzalne środowisko i szybka pętla naprawy

1. Przypiąć sprawdzoną wersję Foundry w instalacji lokalnej i CI. Zachować spójność Solidity, Node i npm; zmiana wersji ma być osobnym, testowanym zadaniem.
2. Używać `npm ci` z istniejącym lockfile oraz inicjalizacji submodułów z wersji przypiętych w Git. Opcjonalny kontener dodać, jeśli nadal występują różnice środowiskowe.
3. Utworzyć `.env.example` z pustymi wartościami pięciu obecnych zmiennych RPC. Opisać wymaganie dostępu do historycznego stanu. Nie dodawać produkcyjnego klucza prywatnego do ścieżki uruchamiania testów.
4. Dodać `npm run agent:doctor`: wersje, zależności, submoduły, obecność wymaganych zmiennych i opcjonalny odczyt chain ID. Raportować brakującą zmienną bez wypisywania jej wartości czy pełnego URL RPC.
5. Stworzyć jawny katalog zestawów testowych, np. `config/test-suites.json`: moduł, ścieżki, rodzaj testu, chain ID, blok, profil EVM, potrzeba FFI i orientacyjny czas. Zweryfikować też helpery wywoływane przez `setUp()`; nazwa katalogu `unitTest` sama nie gwarantuje niezależności od RPC.
6. Zdefiniować profile lokalne, CI i sieciowe po sprawdzeniu istniejących testów. Profil CI i profil sieci muszą składać się w przewidywalny sposób, także dla Arbitrum/Paris.
7. Rozdzielić formatowanie zmieniające pliki od kontroli formatowania. Ujednolicić pre-commit z zależnościami projektu.

Docelowy interfejs, do zaimplementowania:

```bash
npm run agent:doctor
npm run test:unit
npm run test:affected -- --base <commit>
npm run test:fork -- --chain <chain-id> --suite factory --block <block-number>
npm run format:check
```

Selektor `test:affected` powinien uwzględniać importy i mapę modułów. Zmiana wspólnej biblioteki storage, ról, oracle lub księgowania uruchamia szerszy zestaw; nieznana zależność oznacza szersze testy i jawną informację o przyczynie.

Procedura naprawy błędu: reprodukcja → wskazanie przyczyny → poprawka i potrzebny test regresyjny → testy modułu → szersze testy zależne od ryzyka → raport z ograniczeniami. Dla drobnej zmiany dokumentacji wystarczą kontrole dokumentu; nie wymagać zbędnych testów kontraktów.

**Kryterium odbioru:** świeży checkout buduje się według README; lokalny zestaw testów działa bez RPC i sekretów po instalacji zależności; brak RPC jest raportowany jako problem środowiska, a nie pozornie zaliczony fork test.

## 5. Rejestr wdrożeń: podstawa używania istniejących fabryk

### 5.1. Jedno źródło adresów, osobne ABI dla wersji

Utworzyć `deployments/<chain-id>/factories.json` ze schematem `deployments/schema/factories.schema.json`. Zacząć od FusionFactory na jednej zweryfikowanej sieci, potem dodać pozostałe fabryki i sieci.

| Grupa danych | Wymagane informacje |
| --- | --- |
| Tożsamość | Stabilne ID wdrożenia, chain ID, rodzaj fabryki, adres wywołania, status `candidate`, `verified`, `deprecated` lub `unsupported`. |
| Pochodzenie | Źródło adresu, transakcja i blok wdrożenia, link do explorera, osoba/zespół potwierdzający wpis. Nieznane wartości oznaczyć jawnie. |
| Wersja kodu | Adres proxy i implementacji, typ proxy albo brak proxy, hashe runtime bytecode, źródłowy commit/tag jeśli ustalony, ustawienia kompilatora i linkowane biblioteki. |
| Interfejs | Ścieżka i hash ABI, adapter wersji, obsługiwane operacje i sygnatury. Oddzielić wersję raportowaną przez fabrykę od tożsamości implementacji i ABI. |
| Zależności | Odczytane adresy fabryk składowych, baz, middleware i innych wymaganych komponentów; referencje do ich wersji i ABI. |
| Weryfikacja | Numer i hash bloku, czas sprawdzenia, wynik kontroli kodu i testu kompatybilności, odnośnik do raportu. |

ABI w `abi/<release-or-implementation-id>/` musi odpowiadać wdrożonemu kodowi. Generowanie ABI wyłącznie z bieżącego `HEAD` jest dopuszczalne tylko po potwierdzeniu zgodności z wdrożeniem. Jeżeli źródeł wersji nie ma w aktualnym checkoutcie, pozyskać je z właściwego wydania lub zweryfikowanego źródła i zapisać pochodzenie.

Manifest zatwierdza tożsamość wdrożenia, a raporty odczytów przedstawiają stan na bloku. Zmienne pakiety opłat, role i wskaźniki komponentów nie mogą być traktowane jako wieczne stałe w README. Zachować historię upgrade'ów, aby historyczny test nadal wybierał poprawną implementację.

### 5.2. Procedura zebrania i weryfikacji

1. Zebrać kandydatów najpierw z istniejącego rejestru `ipor-abi` i narzędzia `fusion_address_lookup` dostępnego przez MCP, następnie z testów, historii wydań i danych zespołu utrzymującego wdrożenia. Nie zgadywać brakujących adresów. Brak adresu w tym repo nie oznacza braku wdrożenia; lokalny manifest ma wskazywać pochodzenie danych i uzupełniać istniejący rejestr o dowody zgodności.
2. Dla każdego kandydata potwierdzić chain ID, obecność kodu, typ proxy i rzeczywistą implementację; dla ERC1967 odczytać właściwy slot. Sprawdzenie samego kodu proxy nie identyfikuje implementacji.
3. Dopasować ABI i odczytać konfigurację funkcjami dostępnymi w tej wersji. Dla bieżącego kodu punktem odniesienia są m.in. `getFusionFactoryVersion()`, `getFactoryAddresses()`, `getBaseAddresses()` i `getPriceOracleMiddleware()`.
4. Zweryfikować kod również pod wymaganymi adresami komponentów. Gdy porównanie z lokalną kompilacją wymaga uwzględnienia immutables lub linkowania bibliotek, zapisać metodę porównania.
5. Uruchomić test użycia istniejącej fabryki na zapisanym bloku. Nadać status `verified` dopiero po spełnieniu kryteriów; sam fakt istnienia kontraktu nie wystarcza.
6. Przed przygotowaniem operacji ponownie odczytać bieżącą implementację i konfigurację. Nieznana zmiana oznacza konieczność aktualizacji zgodności, a nie automatyczne przyjęcie nowego ABI.

W razie braku wsparcia dla nowszej funkcji narzędzie powinno użyć przetestowanego adaptera starszej wersji albo zwrócić `UNSUPPORTED_FACTORY_VERSION`. Nie może automatycznie upgrade'ować fabryki ani wdrażać zastępczej tylko po to, by scenariusz przeszedł.

**Kryterium odbioru:** agent wskazuje fabrykę wraz z siecią, wersją, ABI i blokiem weryfikacji; każdy wpis `verified` ma raport oraz działający test zgodności z wdrożeniem.

## 6. Wykonywalna procedura użycia fabryki

### 6.1. Semantyka, którą trzeba opisać wprost

W aktualnym [FusionFactory.sol](../contracts/factory/FusionFactory.sol) publiczny `clone(...)` przyjmuje nazwę, symbol, underlying token, redemption delay, ownera i indeks pakietu opłat. `cloneSupervised(...)` wymaga `MAINTENANCE_MANAGER_ROLE`. To opis kodu checkoutu, nie deklaracja interfejsu każdego wdrożenia.

W [FusionFactoryLogicLib.sol](../contracts/factory/lib/FusionFactoryLogicLib.sol) pakiet biznesowy wybierany jest według `msg.sender`, a nie `owner_`. Wywołanie przez EOA, Safe lub dodatkowy kontrakt może więc wybrać inne opłaty. Scenariusz musi rozróżniać podpisującego, bezpośredniego wywołującego fabrykę, właściciela vaulta i operatorów strategii.

Role samej FusionFactory i role vaulta zarządzane przez IporFusionAccessManager należy opisać oddzielnie, łącznie z ich reprezentacją, administratorami i opóźnieniami. Utworzenie vaulta nie oznacza, że strategia ma już skonfigurowane fuse'y, substrates, wyceny i operatorów.

### 6.2. Wejście i narzędzia

Dodać walidowany `config/vaults/example.json`: chain ID, ID wdrożenia, caller, owner, underlying, nazwa i symbol, redemption delay w sekundach, wybrany wariant utworzenia, pakiet opłat oraz oczekiwane wartości i odbiorca opłat. Kwoty tokenów zapisywać jako ciągi liczb całkowitych w najmniejszych jednostkach; jawnie wskazywać decimals, BPS i sekundy.

Proponowane skrypty Foundry: `InspectFactory.s.sol`, `CreateVault.s.sol`, `ConfigureVault.s.sol`, `VerifyVault.s.sol` w `script/factory/`, osłonięte cienkim interfejsem CLI. Przed implementacją skryptu dobrać ABI/adapter do zweryfikowanej fabryki.

Docelowe polecenia — poniższe nazwy jeszcze nie istnieją:

```bash
npm run factory:inspect -- --chain <chain-id> --factory <deployment-id> --json
npm run vault:plan -- --config config/vaults/example.json
npm run vault:simulate -- --plan <plan-file> --block <block-number>
npm run vault:verify -- --chain <chain-id> --tx <transaction-hash> --json
```

### 6.3. Kolejne etapy scenariusza

1. **Inspect:** odczytać chain ID, proxy/implementację, konfigurację baz i fabryk, role wywołującego oraz efektywny pakiet opłat dla faktycznego callera, jeżeli dana wersja obsługuje pakiety. Raport uwzględnia blok i zgodność ABI.
2. **Plan:** zwalidować wejście; sprawdzić kod underlying tokena i jego metadane, wymagane oracle i opóźnienia; przygotować dekodowalne calldata oraz przewidywaną kolejność transakcji. Token i parametry strategii wybiera użytkownik/konfiguracja, agent ich nie wymyśla.
3. **Simulate:** wykonać scenariusz na forku z właściwym callerem i rzeczywistą ścieżką EOA/Safe/kontraktu. Symulacja używa istniejącej fabryki bez podmiany jej kodu, konfiguracji czy uprawnień. Finansowanie testowego konta jest jawne i ograniczone do forka.
4. **Verify simulation:** sprawdzić kod utworzonych komponentów, ich powiązania, ownera, role, underlying, decimals, opłaty, middleware i parametry wypłat. Wskazać wymagane dalsze kroki konfiguracji.
5. **Prepare execution:** wygenerować artefakt z chain ID, callerem, adresami docelowymi, calldata, value, limitem gazu/kosztu, odczytaną wersją wdrożenia, blokiem symulacji i skrótem konfiguracji. Dla wielu transakcji zapisać zależności oraz preconditions kolejnego kroku.
6. **Execute:** odrębna ścieżka wykonawcza korzysta z upoważnionego signera i uzgodnionego zakresu. Przed wysłaniem odświeża stan i symulację. Zmiana opłat, implementacji, parametrów lub odbiorców poza zakresem unieważnia przygotowany plan.
7. **Verify receipt:** po wymaganej dla sieci finalności odczytać receipt, eventy i stan utworzonego vaulta. Zapisać rzeczywiste adresy i wynik sprawdzenia warunków końcowych.

Foundry rozróżnia symulację skryptu od wysłania przez `--broadcast`; oprzeć interfejs na tym rozdzieleniu i dodać osobną kontrolę parametrów oraz wykonawcy. Zob. [Foundry: scripting with config](https://getfoundry.sh/guides/scripting-with-config/).

Wartość `FusionInstance` zwracana przez wywołanie w teście nie jest automatycznie dostępna jako wynik w receipt zwykłej transakcji. [FusionInstanceCreated](../contracts/factory/lib/FusionFactoryLib.sol) zawiera tylko część adresów. Należy połączyć eventy właściwej wersji z odczytami konfiguracji vaulta, filtrować emitenta i nie traktować przewidywanych adresów z symulacji jako ostatecznych.

Przy timeout po wysłaniu nie ponawiać `clone` w ciemno. Najpierw sprawdzić hash transakcji, nonce i receipt. Dziennik wykonania musi odróżniać brak wysłania, pending, revert i sukces, aby retry nie tworzył kolejnego vaulta.

Zmiana stanu między symulacją a włączeniem transakcji do bloku nadal jest możliwa. Jeśli kontrakt nie pozwala atomowo wymusić oczekiwanej wersji/opłat, opisać to ograniczenie w artefakcie. Ewentualny wrapper z takimi sprawdzeniami wymaga osobnego projektu i testów, ponieważ zmienia `msg.sender` widziany przez fabrykę.

### 6.4. Konfiguracja vaulta i scenariusze po utworzeniu

Dodać procedury: utworzenie podstawowego vaulta, konfiguracja jednej prostej integracji ERC4626, dodanie price feedu przez odpowiednią fabrykę oraz utworzenie wrappera. Każda podaje wejście, role, kolejność operacji, wynik, test i typowe reverts.

Pierwszy scenariusz obejmuje konfigurację wymaganych ról, oracle, fuse'ów, balance fuse'ów, substrates i limitów; następnie deposit, dopuszczoną operację strategii, wyjście oraz właściwą dla konfiguracji ścieżkę withdraw/request/redeem. Opóźnienia czasu przyspieszać wyłącznie w środowisku testowym i zaznaczyć różnicę względem sieci.

**Kryterium odbioru:** agent dostaje poprawną konfigurację i przygotowuje sprawdzony plan utworzenia vaulta przez wdrożoną fabrykę; błędny chain ID, ABI, caller, pakiet opłat lub brak roli daje jednoznaczny błąd przed wysłaniem.

## 7. Testy potwierdzające rzeczywiste możliwości

Rozdzielić trzy rodzaje fixture'ów i opisać je w katalogu testów:

| Rodzaj | Co wolno zmieniać | Co udowadnia |
| --- | --- | --- |
| Lokalny deployment | Całe środowisko testowe. | Działanie bieżącego kodu i regresje jednostkowe. |
| Fork z nowym kodem lub upgrade'em | Jawnie wskazane implementacje, konfigurację i role na forku. | Działanie nowej wersji w otoczeniu realnych protokołów. |
| Użycie istniejącego wdrożenia | Stan tworzony przez testowaną operację i jawne finansowanie kont testowych; bez wymiany istniejącej fabryki i jej uprawnień. | Możliwość użycia konkretnej wdrożonej wersji przez wskazanego callera. |

Nowy zestaw `test/deployed-factories/` powinien testować co najmniej:

- Odczyt rejestru, zgodność chain ID, implementacji, ABI i komponentów.
- Utworzenie vaulta zwykłą dostępną ścieżką oraz weryfikację eventów, ról i opłat.
- Odrzucenie operacji wymagającej roli, której caller nie ma.
- Wersje z pakietami opłat: globalny i biznesowy pakiet, różni callerzy i ownerzy, niepoprawny indeks.
- Niezgodną implementację lub nieobsługiwany interfejs oraz zmianę konfiguracji po przygotowaniu planu.
- Konfigurację jednej strategii i pełną testową ścieżkę środków z tolerancjami księgowymi.
- Odczyt wyniku transakcji oraz wznowienie po timeout bez ponownego tworzenia vaulta.

Utrzymać osobno deterministyczne regresje na przypiętych blokach i cykliczny test na świeżym, zdefiniowanym bloku finalnym. Pierwsze chronią kod przed regresją; drugi wykrywa zmianę wdrożenia lub jego zależności. Błąd RPC, brak archive state i niezgodność kontraktu muszą mieć różne kategorie.

**Kryterium odbioru:** pozytywny test użycia wdrożenia nie wymaga `upgradeToAndCall`, podmiany kodu przez cheatcode ani nadania sobie roli administratora fabryki.

## 8. CI, utrzymanie wiedzy i interfejs dla agentów

### 8.1. CI jako kontrola aktualności

- Każdy PR: build, format check, lint, lokalne testy, walidacja schematów, lokalnych linków i zgodności generowanych katalogów z kodem.
- PR zmieniający fabryki/ABI/role/storage: odpowiedni zestaw regresji i testów kompatybilności; oczekiwany zakres zapisany w mapie testów.
- Zaufany job z RPC: testy forkowe i weryfikacja manifestów na wskazanym bloku; raport z przyczyną niepowodzenia.
- Harmonogram, początkowo raz dziennie: kontrola implementacji i wymaganych komponentów zweryfikowanych wdrożeń. Częstotliwość dostosować do procesu upgrade'ów i kosztu RPC.
- Proces wydania: aktualizacja ABI, historii wdrożeń, przykładów i odpowiedzialnego właściciela wpisu. Rozszerzyć `CODEOWNERS` o dokumentację operacyjną i rejestr.

Obecne [ci.yml](../.github/workflows/ci.yml) używa `pull_request_target`, a workflow budujący checkoutuje merge PR i uruchamia kod z dostępem do przekazanych sekretów; występuje też krok `authorize` z environments. Skuteczność zabezpieczenia zależy od ustawień GitHub, których nie sprawdzano. W ramach przygotowania do wkładu agentów zweryfikować ochronę environments i rozdzielić wykonanie niezaufanych PR od uprzywilejowanego dostępu do RPC/sekretów. GitHub opisuje ryzyko takiego połączenia w [Securely using pull_request_target](https://docs.github.com/en/actions/reference/security/securely-using-pull_request_target).

### 8.2. Małe, przewidywalne narzędzia

Najpierw udostępnić CLI na bazie istniejącego stosu Foundry/Node. Każde polecenie powinno mieć schemat wejścia, stabilne kody błędów, tryb JSON oraz krótki czytelny raport. Błędy przykładowe: `RPC_UNAVAILABLE`, `CHAIN_MISMATCH`, `UNVERIFIED_DEPLOYMENT`, `UNSUPPORTED_FACTORY_VERSION`, `MISSING_ROLE`, `FEE_PACKAGE_CHANGED`.

Raport zawiera `schemaVersion`, `status`, `chainId`, `blockNumber`, `blockHash`, `deploymentId`, wynik, ostrzeżenia i referencje do artefaktów. Adresy, calldata i kwoty waliduje kod; agent nie powinien składać krytycznych danych z luźnego opisu tekstowego.

Opcjonalny adapter MCP dodać dopiero, gdy realnie uprości dostęp agentów do tych samych operacji. Może wystawiać `list_deployments`, `inspect_factory`, `explain_revert`, `plan_vault`, `simulate_vault`, `verify_vault`. CLI i adapter muszą korzystać ze wspólnej implementacji. Na start nie potrzeba osobnego serwera wiedzy ani indeksu wektorowego: wystarczą krótkie dokumenty, katalogi JSON i wyszukiwanie kodu.

Signer i zakres wykonania utrzymywać poza treścią promptów i dokumentacji. Autoryzacja powinna dotyczyć sieci, kontraktów, operacji, callerów i limitów; uwzględniać wcześniej udzielony zakres, zamiast wymuszać ręczne potwierdzenie każdego odczytu czy powtórzenia symulacji. Treści issue, komentarze, metadane tokenów i wyniki narzędzi są danymi, a nie upoważnieniem do poszerzenia zakresu operacji.

## 9. Zadania atomowe — jedno zadanie, jeden commit

### 9.1. Jak realizujemy zadania

- Każde `Txx` ma jeden rezultat, jawne zależności, granice zakresu, kryterium odbioru i proponowany komunikat commita. Kod, potrzebne testy i instrukcja użycia tej jednej funkcji należą do tego samego zadania.
- `[ ]` oznacza niezakończone, `[x]` zakończone i zweryfikowane. Przy zadaniu zablokowanym dopisujemy konkretny brak. Checkbox zmieniamy razem z implementacją; ID zadania w komunikacie commita pozwala odnaleźć zmianę przez Git.
- Bierzemy jedno wskazane zadanie. Sprawdzamy stan repo i zależności, realizujemy zakres, weryfikujemy go, przeglądamy diff, commitujemy wyłącznie jego pliki i kończymy. Nie przechodzimy automatycznie do następnego zadania.
- Jeśli commit jest niemożliwy w danym środowisku, raportujemy „zaimplementowane, niecommitowane”, podajemy pliki i dokładną komendę dla hosta. Nie oznaczamy zadania jako zakończonego. Nie używamy `git add .` przy cudzych zmianach.
- Commit ma działać bez następnego zadania. Nie dodajemy aktywnych skryptów npm wskazujących nieistniejące pliki, pozornie zaliczonych testów ani manifestów `verified` bez dowodów. Test zgodności może jawnie używać wpisu `candidate` przed jego promocją; polecenia operacyjne tego nie mogą.
- `S` = zwykle 1–3 godziny, `M` = zwykle 3–6 godzin bez oczekiwania na dane/RPC/review. Jeśli w trakcie zadanie przekracza jeden dzień albo obejmuje drugi niezależny rezultat, rozbijamy je przed dalszą implementacją na `Txxa`, `Txxb`, zachowując zależności.
- Zadania operacyjne w tym backlogu oznaczają przygotowanie narzędzi i testy lokalne/na forku. Rzeczywiste wysłanie transakcji na sieć publiczną jest osobnym wykonaniem w uzgodnionym zakresie.
- Zachowujemy istniejące ustawienia kompilacji. `via_ir = true` jest zabronione; propozycja zmiany Solidity, EVM lub optymalizatora wymaga osobnego uzgodnienia z Pete'em. Ten podział planu nie jest zgodą na taką zmianę.

Wspólne kryterium commita: zakres zadania wykonany, odpowiednie sprawdzenie zakończone, brak sekretów i przypadkowego formatowania innych plików, aktualna instrukcja użycia oraz zaznaczony status. Dla dokumentacji wystarczy kontrola treści i linków; dla obsługi transakcji wymagane są testy zachowania i błędów.

### 9.2. Punkt odniesienia i uruchomienie repo

#### T00 — Pomiar bazowy przed usprawnieniami

- [ ] **P0 · M · Zależności: brak.**
- **Zakres:** zdefiniować osiem zadań z sekcji 10 w `evals/agent-readiness/tasks.json`; zapisać warunki i pierwszy wynik w `evals/agent-readiness/baseline.md`. Nie budować jeszcze runnera.
- **Odbiór:** wynik podaje commit, model, narzędzia, limit pracy, rezultaty i braki dostępu. Dla porównania samego repo używać sesji bez prywatnej pamięci; nie nazywać tego pomiarem sprzed konfiguracji pamięci.
- **Commit:** `docs(agents): T00 record readiness baseline`.
- **Blokada:** brak pierwszego wyniku — pomiar musi zostać uruchomiony w sesjach bez prywatnej pamięci (`claude --bare` wymaga `ANTHROPIC_API_KEY`/`apiKeyHelper`, nieustawionego w tym środowisku). Definicja zadań i warunki są gotowe w `evals/agent-readiness/`.

#### T01 — Selektywne wersjonowanie dokumentacji

- [x] **P0 · S · Zależności: T00.**
- **Zakres:** poprawić `.gitignore` i dodać `docs/README.md` jako indeks. Dopuścić tylko uzgodnione pliki/katalogi dokumentacji; istniejące prywatne materiały w `docs/` pozostają ignorowane.
- **Odbiór:** `git check-ignore` i `git status` potwierdzają, że indeks można dodać, a lokalne notatki i `.env` nie zostały ujawnione. Kolejne zadania dodają potrzebne wyjątki razem z dokumentem.
- **Commit:** `docs(agents): T01 track curated project documentation`.

#### T02 — Działający przykład konfiguracji RPC

- [x] **P0 · S · Zależności: T01.**
- **Zakres:** dodać `.env.example` z pięcioma pustymi zmiennymi RPC i uzupełnić odpowiedni fragment README o archive state.
- **Odbiór:** wszystkie nazwy odpowiadają testom; brak wartości sekretów i kluczy do podpisywania; link w README działa.
- **Commit:** `docs(setup): T02 add RPC environment template`.

#### T03 — Instalacja zgodna z lockfile

- [x] **P0 · S · Zależności: T02.**
- **Zakres:** ujednolicić README i instalację w CI wokół `npm ci` oraz przypiętych submodułów. Nie aktualizować zależności.
- **Odbiór:** czysta instalacja odtwarza zależności bez zmian lockfile; brakujący submoduł ma opisaną procedurę uzupełnienia.
- **Commit:** `build(deps): T03 use reproducible dependency installation`.

#### T04 — Przypięcie wersji Foundry

- [x] **P0 · S · Zależności: T03.**
- **Zakres:** zapisać sprawdzoną wersję Foundry i użyć jej w CI oraz instrukcji lokalnej. Bez zmiany parametrów kompilatora.
- **Odbiór:** lokalnie i w CI wskazana jest ta sama wersja; build i reprezentatywny test fabryki przechodzą.
- **Commit:** `build(foundry): T04 pin the validated toolchain`.

#### T05 — Kontrola formatowania bez zapisu

- [x] **P0 · S · Zależności: T03.**
- **Zakres:** dodać `format:check` w `package.json`, korzystając z obecnego Prettier. Pozostawić komendy formatujące jako osobne operacje; podłączenie do CI jest w T43.
- **Odbiór:** poprawny plik przechodzi, celowo błędny plik testowy daje niezerowy exit code, żaden plik nie jest zmieniany. Zastane błędy formatowania są raportowane, nie masowo naprawiane.
- **Commit:** `build(format): T05 add a non-mutating format check`.

#### T06 — Spójne formatowanie w pre-commit

- [x] **P1 · S · Zależności: T05.**
- **Zakres:** wyrównać wersje Prettier i pluginu Solidity w `.pre-commit-config.yaml` do `package.json`.
- **Odbiór:** pre-commit i lokalny formatter dają ten sam wynik na tej samej próbce; bez formatowania całego repo.
- **Commit:** `build(format): T06 align pre-commit formatter versions`.

#### T07 — Usunięcie niedziałającej komendy coverage

- [x] **P1 · S · Zależności: T03.**
- **Zakres:** potwierdzić brak `tools/check_coverage.sh`; jeżeli nadal go nie ma, usunąć martwy skrypt `coverage:file` i odwołania. Nie projektować systemu coverage w tym zadaniu.
- **Odbiór:** żaden skrypt npm nie wskazuje tego brakującego pliku; ewentualnie odnaleziona, istniejąca implementacja jest poprawnie podłączona i sprawdzona.
- **Commit:** `build(scripts): T07 fix the stale coverage command`.

### 9.3. Instrukcje dla agentów

#### T08 — Wspólny punkt wejścia do repo

- [x] **P0 · S · Zależności: T01, T04, T05.**
- **Zakres:** dodać główny `AGENTS.md` i cienki projektowy `CLAUDE.md` wskazujący wspólne instrukcje, z odpowiednim wyjątkiem `.gitignore`. Dodać link z README.
- **Odbiór:** dokument podaje tylko istniejące komendy i pliki; zawiera reguły projektu, w tym zakaz `via_ir`, bez danych z prywatnej pamięci. Każdy używany klient potrafi odnaleźć wspólne instrukcje.
- **Commit:** `docs(agents): T08 add shared repository instructions`.

#### T09 — Mapa architektury vaulta

- [x] **P1 · S · Zależności: T08.**
- **Zakres:** `docs/architecture.md` z punktami wejścia, routingiem `delegatecall`, storage i managerami; odwołania do istniejącego opisu vaultów.
- **Odbiór:** reprezentatywne ścieżki deposit, execute i fallback są sprawdzone względem kodu; linki wskazują istniejące symbole/pliki.
- **Commit:** `docs(architecture): T09 map vault execution and storage`.

#### T10 — Mapa ról i wywołujących

- [x] **P0 · S · Zależności: T09.**
- **Zakres:** `docs/roles-and-permissions.md`: role fabryki i vaulta, caller kontra owner, administratorzy i opóźnienia. Bez deklarowania aktualnych posiadaczy ról on-chain.
- **Odbiór:** każdy opis uprawnienia ma źródło w kodzie; wyjaśniony wpływ callera na pakiet opłat.
- **Commit:** `docs(access): T10 explain factory and vault permissions`.

#### T11 — Instrukcje pracy nad fabrykami

- [x] **P0 · S · Zależności: T08, T10.**
- **Zakres:** `contracts/factory/AGENTS.md` oraz krótki `docs/factories.md` opisujący wybór rodzaju fabryki i wersji. Wskazać FeeManagerFactory spoza katalogu factory.
- **Odbiór:** agent znajduje kod i testy tworzenia vaulta; instrukcja odróżnia lokalne wdrożenie, upgrade na forku i użycie istniejącej fabryki.
- **Commit:** `docs(factory): T11 add factory development guidance`.

#### T12 — Instrukcje pracy nad fuse'ami

- [x] **P1 · S · Zależności: T08, T09.**
- **Zakres:** `contracts/fuses/AGENTS.md`: wybór istniejącej integracji jako wzorca, substrates, balance fuse, wyceny i testy. Bez refaktoryzacji fuse'ów.
- **Odbiór:** jedna istniejąca integracja pozwala przejść instrukcję od źródła do właściwego testu.
- **Commit:** `docs(fuses): T12 add fuse development guidance`.

### 9.4. Dobór i uruchamianie testów

#### T13 — Katalog testów dla pilotażu fabryki

- [x] **P0 · M · Zależności: T04, T11.**
- **Zakres:** `config/test-suites.json`, jego schemat, `test/AGENTS.md` i początek `docs/testing.md`. Sklasyfikować wyłącznie testy potrzebne do pilotażu fabryki; reszta pozostaje jawnie niesklasyfikowana.
- **Odbiór:** wpisy określają RPC, blok, profil, FFI i typ fixture'a; sprawdzone również helpery w `setUp()`. Błędny wpis nie przechodzi walidacji.
- **Commit:** `test(catalog): T13 classify factory pilot suites`.

#### T14 — Jawne profile uruchamiania testów

- [x] **P0 · S · Zależności: T13.**
- **Zakres:** uporządkować dobór istniejących profili dla lokalnych testów, CI i Arbitrum; opisać efektywną konfigurację. Zawęzić FFI/fs permissions tylko dla pilotażowego zestawu, który ich nie potrzebuje.
- **Odbiór:** wymagane zestawy nadal działają; kompilator, optimizer i wersje EVM pozostają zgodne z dotychczasowymi profilami. Potrzeba zmiany tych wartości oznacza osobną propozycję, nie obejście.
- **Commit:** `test(config): T14 make test profiles explicit`.

#### T15 — Lokalny zestaw bez RPC

- [x] **P0 · M · Zależności: T13, T14.**
- **Zakres:** zaimplementować `npm run test:unit` dla zweryfikowanego podzbioru testów i opisać jego pokrycie. Nie przemieszczać wszystkich testów.
- **Odbiór:** zestaw działa bez RPC po instalacji zależności; pusta selekcja lub błąd Forge daje niezerowy kod wyjścia.
- **Commit:** `test(runner): T15 add an RPC-free unit suite`.

#### T16 — Uruchamianie jednego zestawu na forku

- [x] **P0 · M · Zależności: T13, T14.**
- **Zakres:** `test:fork -- --chain … --suite factory --block …`; sprawdzić, czy podany blok rzeczywiście dociera do fixture'a, także gdy test wcześniej miał stałą w `setUp()`.
- **Odbiór:** jedna sieć i suite działają na zadanym bloku; brak RPC, niewspierana sieć, ignorowany parametr i pusta selekcja są widocznymi błędami.
- **Commit:** `test(runner): T16 add a pinned factory fork runner`.

#### T17 — Diagnostyka lokalnego środowiska

- [x] **P0 · S · Zależności: T03, T04, T13.**
- **Zakres:** `agent:doctor` sprawdza wersje, zależności, submoduły oraz obecność zmiennych; tryb tekstowy i JSON. Bez połączeń sieciowych.
- **Odbiór:** brak zależności daje konkretną wskazówkę i kod błędu; raport nie wypisuje wartości zmiennych ani sekretów.
- **Commit:** `feat(tooling): T17 add local environment diagnostics`.

#### T18 — Opcjonalna diagnostyka RPC

- [x] **P0 · S · Zależności: T16, T17.**
- **Zakres:** dodać do doctor jawny tryb sprawdzający jedną wskazaną sieć: chain ID, odpowiedź RPC i odczyt stanu na bloku pilotażu.
- **Odbiór:** rozróżniane są niedostępny RPC, zła sieć i brak historycznego stanu; odpowiedzi błędów nie ujawniają URL z kluczem.
- **Commit:** `feat(tooling): T18 add opt-in RPC diagnostics`.

#### T19 — Konserwatywny dobór testów do zmiany

- [x] **P1 · M · Zależności: T13, T15, T16.**
- **Zakres:** `test:affected -- --base …` z mapą modułów i zależności importów dla pilotażu. Nieznana ścieżka lub zmiana wspólnego storage/ról/oracle wybiera szerszy zestaw i podaje powód.
- **Odbiór:** przykłady zmiany fabryki, biblioteki wspólnej, helpera i niesklasyfikowanego pliku dobierają wystarczający zakres; brak RPC nie jest traktowany jako zaliczenie.
- **Commit:** `test(runner): T19 select affected suites conservatively`.

### 9.5. Pierwsza istniejąca fabryka

#### T20 — Ustalenie źródła adresów i wybór pilotażu

- [x] **P0 · S · Zależności: T11.**
- **Zakres:** sprawdzić `ipor-abi`/`fusion_address_lookup`, zapisać źródła i wybrać jedną parę sieć–FusionFactory w `docs/deployments.md`. Nie dopisywać zgadywanych adresów.
- **Odbiór:** kandydat ma pochodzenie i jawny status niezweryfikowany; ustalono, które dane odtwarzamy z istniejącego rejestru, a które utrzymujemy lokalnie.
- **Commit:** `docs(deployments): T20 select the factory pilot and address sources`.

#### T21 — Schemat i walidator manifestów

- [x] **P0 · M · Zależności: T20.**
- **Zakres:** schemat z sekcji 5, walidator i syntetyczne fixtures poza katalogiem produkcyjnych wdrożeń. Ustalić strukturę referencji do ABI i raportów.
- **Odbiór:** walidacja wykrywa m.in. zły adres, chain ID, brak ABI i niedozwolone oznaczenie `verified` bez referencji do dowodu.
- **Commit:** `feat(deployments): T21 validate factory manifests`.

#### T22 — ABI jednej wdrożonej wersji

- [x] **P0 · M · Zależności: T20, T21.**
- **Zakres:** pozyskać ABI pilotażowej implementacji do `abi/<version>/` wraz z pochodzeniem i hashem. Dodać minimalny interfejs/adapter, jeśli bieżący kontrakt ma inny interfejs.
- **Odbiór:** potwierdzono powiązanie ABI z kodem implementacji; test kodowania/dekodowania obejmuje operację potrzebną do utworzenia vaulta. Brak źródła wersji blokuje zadanie.
- **Commit:** `feat(abi): T22 add the pilot factory interface`.

#### T23 — Manifest pierwszego kandydata

- [x] **P0 · S · Zależności: T21, T22.**
- **Zakres:** dodać jeden manifest `candidate` z siecią, adresem, ABI, znanymi komponentami i pochodzeniem danych.
- **Odbiór:** walidator przechodzi; dane nieustalone są jawne; status nadal nie sugeruje gotowości operacyjnej.
- **Commit:** `feat(deployments): T23 register the pilot factory candidate`.

#### T24 — Odczyt i weryfikacja tożsamości fabryki

- [x] **P0 · M · Zależności: T18, T23.**
- **Zakres:** `factory:inspect` dla pilotażu: chain ID, proxy/implementacja, kod, dostępne gettery, komponenty, caller i efektywne opłaty. Zapis odczytów na jednym bloku w uzgodnionym formacie JSON.
- **Odbiór:** rzeczywisty odczyt działa; zły chain ID, brak kodu i niezgodna wersja mają różne błędy. Odczyt kandydata nie nadaje mu automatycznie statusu `verified`.
- **Commit:** `feat(factory): T24 inspect deployed factory identity and configuration`.

#### T25 — Test tworzenia przez niezmienioną fabrykę

- [ ] **P0 · M · Zależności: T16, T24.**
- **Zakres:** jeden test w `test/deployed-factories/` tworzący vault przez pilotażową wersję z właściwym ABI i callerem; sprawdzenie podstawowych adresów, ownera i opłat.
- **Odbiór:** test działa na przypiętym bloku bez upgrade'u, podmiany istniejących fabryk i nadawania sobie ich ról. Wpis `candidate` jest dopuszczony wyłącznie do tego testu zgodności.
- **Commit:** `test(factory): T25 exercise the unchanged deployed factory`.

#### T26 — Promocja pilotażu do verified

- [ ] **P0 · S · Zależności: T24, T25.**
- **Zakres:** zapisać pozbawiony sekretów raport odczytów i testu, numer/hash bloku oraz wersję narzędzi; zmienić status jednego manifestu.
- **Odbiór:** manifest `verified` odsyła do odtwarzalnego dowodu zgodności, a nie samego zapewnienia w dokumencie.
- **Commit:** `chore(deployments): T26 verify the pilot factory manifest`.

### 9.6. Planowanie i symulacja utworzenia vaulta

#### T27 — Walidowana konfiguracja vaulta

- [ ] **P0 · M · Zależności: T10, T26.**
- **Zakres:** schemat wejścia i przykład z sekcji 6.2, walidator nazw, adresów, jednostek, callera, ownera i oczekiwanych opłat. Tylko wariant obsługiwany przez pilotaż.
- **Odbiór:** poprawny przykład przechodzi; błędne jednostki, niepełny pakiet opłat i niewspierany wariant są odrzucane. Pola wyboru użytkownika nie mają ukrytych domyślnych odbiorców.
- **Commit:** `feat(vault): T27 validate vault creation configuration`.

#### T28 — Plan jednej operacji utworzenia

- [ ] **P0 · M · Zależności: T24, T27.**
- **Zakres:** `vault:plan` generuje calldata, adres docelowy, caller/value, oczekiwaną implementację i opłaty, blok odczytu oraz hash wejścia. Bez podpisywania i wysyłania.
- **Odbiór:** calldata dekoduje się do danych wejściowych; manifest niezweryfikowany, niezgodność wersji i zły pakiet opłat zatrzymują planowanie.
- **Commit:** `feat(vault): T28 build a verifiable creation plan`.

#### T29 — Symulacja przygotowanego planu

- [ ] **P0 · M · Zależności: T25, T28.**
- **Zakres:** `vault:simulate` wykonuje dokładnie przygotowane calldata na forku z przypiętym blokiem i właściwym callerem. Na początek jedna ścieżka EOA; inne zwracają jawny brak wsparcia.
- **Odbiór:** raport podaje sukces/revert, gas, blok i hash planu; nie ma broadcastu ani automatycznej naprawy fabryki na forku.
- **Commit:** `feat(vault): T29 simulate creation plans on a fork`.

#### T30 — Sprawdzenie stanu utworzonego vaulta

- [ ] **P0 · M · Zależności: T29.**
- **Zakres:** wspólny verifier adresów komponentów, powiązań, ownera, ról, underlying, decimals, opłat, oracle i parametrów wypłat. Podłączyć do wyniku symulacji.
- **Odbiór:** poprawny vault przechodzi, celowo błędne oczekiwania nie; test nie zalicza samego istnienia adresu jako dowodu poprawności całej konfiguracji.
- **Commit:** `feat(vault): T30 verify created vault state`.

#### T31 — Odtworzenie wyniku z receipt

- [ ] **P0 · M · Zależności: T30.**
- **Zakres:** `vault:verify -- --chain … --tx …` odczytuje receipt, filtruje emitenta, dekoduje eventy ABI właściwej wersji i uzupełnia adresy odczytami stanu.
- **Odbiór:** transakcja testowa na Anvil/forku zwraca rzeczywiste adresy; revert, pending, brak finalności i obcy event są rozróżniane. Nie polegać na return value z testu Solidity.
- **Commit:** `feat(vault): T31 resolve creation results from receipts`.

#### T32 — Recepta utworzenia podstawowego vaulta

- [ ] **P0 · S · Zależności: T26, T28, T29, T30, T31.**
- **Zakres:** `docs/recipes/create-vault.md` łączy istniejące inspect → plan → simulate → verify, pokazuje wejście, rezultat i ograniczenia pilotażu.
- **Odbiór:** przejście instrukcji w świeżym środowisku daje zweryfikowany vault na forku bez dodatkowych ustaleń poza dokumentacją i parametrami użytkownika.
- **Commit:** `docs(vault): T32 add the deployed-factory creation recipe`.

### 9.7. Jedna kompletna strategia

#### T33 — Katalog danych jednej integracji ERC4626

- [ ] **P1 · M · Zależności: T12, T20.**
- **Zakres:** schemat `catalog/fuses.json` i jedna pozycja pilotażowa: supply/balance fuse, market ID, substrates, ABI danych, oracle, role, testy i pochodzenie adresów.
- **Odbiór:** pozycja jest zgodna z kodem oraz istniejącym rejestrem; pola niezweryfikowane nie są przedstawiane jako wdrożone i gotowe do użycia.
- **Commit:** `feat(catalog): T33 describe the ERC4626 pilot integration`.

#### T34 — Generowanie strukturalnej części katalogu

- [ ] **P1 · M · Zależności: T33.**
- **Zakres:** generator struktur/selektorów/odnośników do źródeł dla pilotażu; zachować oddzielnie ręczne opisy znaczenia parametrów i zweryfikowane adresy.
- **Odbiór:** ponowne generowanie jest deterministyczne; zmiana odpowiedniej struktury Solidity zmienia wynik, a generator nie nadpisuje informacji redakcyjnych.
- **Commit:** `feat(catalog): T34 generate pilot fuse interface metadata`.

#### T35 — Plan konfiguracji jednej strategii ERC4626

- [ ] **P1 · M · Zależności: T10, T30, T33.**
- **Zakres:** skrypt/plan konfigurujący wymagane role, feeds, fuse'y, balance fuse'y, substrates i limity wyłącznie tej integracji. Ponownie użyć zweryfikowanych wdrożeń komponentów.
- **Odbiór:** na forku właściwi operatorzy konfigurują vault; brak roli lub błędna konfiguracja daje czytelny błąd. Nie dodawać obsługi innych protokołów.
- **Commit:** `feat(vault): T35 configure the ERC4626 pilot strategy`.

#### T36 — Test pełnego cyklu środków i recepta

- [ ] **P1 · M · Zależności: T32, T35.**
- **Zakres:** jeden scenariusz deposit → operacja strategii → wyjście → właściwy withdraw/request/redeem oraz `docs/recipes/erc4626-strategy.md`.
- **Odbiór:** sprawdzone salda i tolerancje księgowe, respektowane role i opóźnienia; pomocnicze finansowanie i przyspieszanie czasu oznaczone jako wyłącznie testowe.
- **Commit:** `test(vault): T36 cover the pilot strategy asset lifecycle`.

#### T37 — Mapa niezmienników i ich testów

- [ ] **P1 · S · Zależności: T09, T30, T36.**
- **Zakres:** `docs/invariants.md` dla księgowania, opłat, wypłat i uprawnień pilotażu; odnośniki do testów, rounding i tolerancji.
- **Odbiór:** każda własność ma oznaczenie „testowana” lub „postulowana”; luki w testach są jawne. Nowe testy większych braków stają się osobnymi zadaniami.
- **Commit:** `docs(testing): T37 map pilot invariants to evidence`.

#### T38 — Procedura diagnozowania najczęstszych błędów

- [ ] **P1 · S · Zależności: T18, T24, T31, T36.**
- **Zakres:** `docs/troubleshooting.md`: konkretne błędy RPC, ABI, ról, opłat, substrates i oracle oraz komendy prowadzące do ich rozpoznania.
- **Odbiór:** przykłady pochodzą z istniejących testów/raportów, a opis prowadzi od objawu do sprawdzenia przyczyny, bez zgadywania naprawy.
- **Commit:** `docs(debugging): T38 add factory and vault troubleshooting`.

### 9.8. Przygotowanie kontrolowanego wykonania

#### T39 — Walidacja planu bezpośrednio przed wykonaniem

- [ ] **P1 · M · Zależności: T28, T29, T30.**
- **Zakres:** preflight sprawdzający aktualny chain ID, implementację, komponenty, callera, opłaty i limity względem artefaktu. Ponowna symulacja aktualnego stanu; nadal bez signera.
- **Odbiór:** zmiana implementacji, odbiorcy/opłat lub zakresu unieważnia plan; opisane pozostaje ryzyko zmiany stanu po symulacji, którego obecny kontrakt nie wymusza atomowo.
- **Commit:** `feat(execution): T39 revalidate plans before execution`.

#### T40 — Dziennik transakcji i bezpieczne wznowienie

- [ ] **P1 · M · Zależności: T31, T39.**
- **Zakres:** trwałe stany przygotowana/pending/reverted/confirmed/unknown, identyfikacja planu, hash transakcji i nonce; odzyskiwanie po timeout. Bez integracji z produkcyjnym signerem.
- **Odbiór:** zasymulowana utrata odpowiedzi po wysłaniu prowadzi do sprawdzenia poprzedniej transakcji; nie powoduje automatycznego kolejnego utworzenia vaulta.
- **Commit:** `feat(execution): T40 persist transaction state and recovery`.

#### T41 — Jeden adapter podpisywania i wykonania EOA

- [ ] **P1 · M · Zależności: T39, T40.**
- **Zakres:** dodać jeden uzgodniony sposób podpisywania zewnętrznego względem promptu, wykorzystujący preflight i dziennik. Testy na Anvil/forku; bez rzeczywistej operacji na mainnecie.
- **Odbiór:** wykonywane są wyłącznie dane zatwierdzonego planu w zadanym zakresie; klucz nie trafia do raportu, promptu ani argumentów widocznych w logach.
- **Commit:** `feat(execution): T41 execute validated plans through an EOA signer`.

#### T42 — Eksport dla Safe i właściwa ścieżka callera

- [ ] **P1 · M · Zależności: T10, T28, T29, T39.**
- **Zakres:** eksport planu w formacie obsługiwanym przez wybrany Safe oraz symulacja wywołania przez Safe jako bezpośredniego callera fabryki. Bez publikowania propozycji transakcji do zewnętrznej usługi.
- **Odbiór:** pakiet opłat i role są sprawdzane dla Safe; test wykrywa różnicę względem EOA właściciela. Nie wdrażać dodatkowego wrappera wywołania.
- **Commit:** `feat(execution): T42 export and simulate Safe creation plans`.

### 9.9. Utrzymanie w CI i mierzenie efektów

#### T43 — Podstawowe CI bez sekretów

- [ ] **P0 · M · Zależności: T04, T05, T15.**
- **Zakres:** uruchamiać build, lint, format check i lokalne testy dla PR bez dostępu do sekretów. Oddzielić powiadomienia wymagające uprawnień od wykonania kodu PR.
- **Odbiór:** przejrzana ścieżka PR z forka i uprawnienia jobów; brak wykonywania jego kodu z sekretami. Przy zastanych błędach wskazać baseline zamiast ukrywać błędy lub formatować repo w tym zadaniu.
- **Commit:** `ci(agents): T43 run secret-free pull request checks`.

#### T44 — Osobny zaufany job testów forkowych

- [ ] **P1 · M · Zależności: T16, T18, T25, T43.**
- **Zakres:** dodać job pilotażowy z RPC i jawnymi zasadami dostępu do sekretów; zachować istniejące użyteczne kontrole podczas migracji workflow.
- **Odbiór:** pozytywny przebieg na przypiętym bloku i czytelny błąd infrastruktury; nieznane ustawienia GitHub environments są wskazane do sprawdzenia. Bez automatycznej zmiany uprawnień organizacji.
- **Commit:** `ci(factory): T44 add trusted pilot fork checks`.

#### T45 — Kontrola aktualności dokumentów i artefaktów

- [ ] **P1 · M · Zależności: T21, T26, T34, T43.**
- **Zakres:** job walidujący lokalne linki dokumentacji, schematy i referencje manifestów oraz brak różnic po generacji katalogu. Bez zależności od dostępności zewnętrznych stron.
- **Odbiór:** celowo zerwany link, brak ABI i nieaktualny artefakt powodują błąd; prywatne, ignorowane dokumenty są poza zakresem.
- **Commit:** `ci(docs): T45 validate documentation and generated metadata`.

#### T46 — Wykrywanie zmian jednego wdrożenia

- [ ] **P1 · M · Zależności: T24, T26, T44.**
- **Zakres:** cykliczny odczyt pilotażowej fabryki i jej zależności na świeżym bloku finalnym; raport różnic implementacji/konfiguracji z ostatnim potwierdzonym stanem.
- **Odbiór:** zmiana implementacji i awaria RPC są różnymi wynikami; raport nie promuje automatycznie nowej wersji i nie zmienia historycznych fixture'ów. Wynik publikowany jako artefakt/status CI.
- **Commit:** `ci(deployments): T46 detect pilot factory drift`.

#### T47 — Odpowiedzialność za rejestr i proces wydania

- [ ] **P1 · S · Zależności: T26, T45.**
- **Zakres:** wskazać istniejących, właściwych właścicieli w `CODEOWNERS`; opisać aktualizację ABI, manifestów, historii i recept przy wydaniu.
- **Odbiór:** checklistę da się przejść na pilotażowym przykładzie; właściciele nie są wymyślonymi kontami, a dokumenty nie sugerują, że monitoring zastępuje review.
- **Commit:** `docs(release): T47 assign deployment documentation ownership`.

#### T48 — Powtarzalny benchmark i porównanie z baseline

- [ ] **P1 · M · Zależności: T00, T19, T32, T36, T38.**
- **Zakres:** prosty runner lub udokumentowany protokół oceny ośmiu zadań, walidacja wyników oraz raport po zmianach w `evals/agent-readiness/`. Warunki zgodne z T00.
- **Odbiór:** raport pokazuje skuteczność, interwencje, czas i koszt; odróżnia brak dostępu od porażki rozwiązania. Zmiana modelu, pamięci lub środowiska jest widoczna, a nie przypisana jakości repo.
- **Commit:** `test(agents): T48 measure readiness against the baseline`.

### 9.10. Rozszerzenia po pilotażu

Przed rozpoczęciem T49–T52 wpisujemy w wybranym zadaniu konkretny wariant/sieć. Każdy kolejny wariant otrzymuje osobne ID, zakres i commit; nie rozszerzamy raz wybranego zadania na wszystkie wdrożenia.

#### T49 — Jedna fabryka price feedu

- [ ] **P2 · M · Zależności: T21, T24, T32, T33.**
- **Zakres:** jedna wskazana, istniejąca fabryka price feedu na sieci pilotażu: ABI, manifest, przykład użycia i test na forku. Bez projektowania nowego oracle.
- **Odbiór:** feed utworzony przez istniejące wdrożenie ma poprawne źródła, jednostki i wynik odczytu; pochodzenie wersji jest potwierdzone.
- **Commit:** `feat(price-feed): T49 support one deployed feed factory`.

#### T50 — Jeden wariant wrappera

- [ ] **P2 · M · Zależności: T21, T24, T32.**
- **Zakres:** jedna istniejąca fabryka wrappera: ABI/manifest, recepta i test utworzenia dla pilotażowego vaulta. Whitelist i zwykły wrapper traktować jako różne warianty.
- **Odbiór:** test sprawdza powiązanie z vaultem i uprawnienia/ograniczenia właściwe wybranemu wariantowi.
- **Commit:** `feat(wrapper): T50 support one deployed wrapper variant`.

#### T51 — Jedna dodatkowa sieć dla istniejącej wersji

- [ ] **P2 · M · Zależności: T16, T24, T32, T44.**
- **Zakres:** dla tej samej obsługiwanej rodziny ABI dodać jedną sieć, manifest, profil wyboru testów i jeden test użycia wdrożenia. Nie zmieniać parametrów kompilacji bez osobnego uzgodnienia.
- **Odbiór:** pełna recepta działa na drugiej sieci bez mieszania adresów/tokenów. Inne ABI wymaga osobnego zadania adaptera przed rozszerzeniem sieci.
- **Commit:** `feat(deployments): T51 support one additional network`.

#### T52 — Opcjonalny odczyt manifestów i inspekcja przez MCP

- [ ] **P2 · M · Zależności: T24, T26, T46.**
- **Zakres:** najpierw sprawdzić możliwości istniejącego MCP; jeśli brak dostępu do nowych dowodów zgodności, dodać tylko `list_deployments` i `inspect_factory`, współdzielące implementację CLI. Bez tworzenia drugiego rejestru.
- **Odbiór:** te same dane wejściowe dają ten sam wynik CLI/MCP; brak możliwości wysyłania transakcji. Jeśli istniejący serwer wystarcza, rezultatem jest przetestowana recepta jego użycia, bez nowego serwera.
- **Commit:** `feat(mcp): T52 expose verified deployment inspection`.

### 9.11. Kolejność i punkty kontrolne

Numeracja grupuje tematy; **zależności określają gotowość zadania**. Możemy realizować pojedynczo dowolne zadanie z zakończonymi zależnościami. Przykładowo T43 warto wykonać zaraz po T15, a nie czekać na narzędzia transakcyjne.

| Punkt kontrolny | Wymagane rezultaty | Co potrafi agent |
| --- | --- | --- |
| Start pracy | T00–T05, T08, T13–T18 wraz z zależnościami | Instaluje repo, dobiera pilotażowy zestaw, diagnozuje środowisko i uruchamia testy. |
| Istniejąca fabryka | T20–T32 wraz z zależnościami | Znajduje zgodne wdrożenie, tworzy plan, symuluje utworzenie i weryfikuje vault. |
| Strategia | T33–T38 wraz z zależnościami | Konfiguruje jedną integrację i weryfikuje cykl środków. |
| Przygotowane wykonanie | T39–T42 wraz z zależnościami | Przygotowuje i testuje operację dla EOA/Safe, wykrywa zmiany stanu i obsługuje retry. |
| Utrzymanie | T43–T48 wraz z zależnościami | Dostaje aktualne instrukcje i dowody w CI; skuteczność jest mierzona. |

Rekomendowany pierwszy task: **T00**, następnie **T01**. Przed implementacją warto osobno zacommitować samą tę listę: `docs(agents): split readiness plan into atomic tasks`.

Po pilotażu osobnymi zadaniami rozszerzamy katalog testów i fuse'ów po jednej integracji, dodajemy kolejne sieci i wersje ABI oraz ewentualne operacje MCP plan/simulate/verify. Kontener środowiska dodajemy tylko wtedy, gdy pomiary wykażą nierozwiązane różnice instalacji. Każde takie rozszerzenie ma przejść ten sam standard jednego rezultatu i jednego commita.

## 10. Jak zmierzyć, czy repo rzeczywiście stało się przyjazne

Przed zmianami wykonać pomiar bazowy, potem powtarzać te same zadania w świeżych sesjach agentów przy tym samym modelu, narzędziach, budżecie i warunkach środowiska. Zapis „nie wykonałem testu, bo brak RPC” jest poprawnym raportem ograniczenia, ale nie zaliczeniem zadania.

Zestaw startowy:

1. Znajdź miejsce odpowiedzialne za konkretny revert i odtwórz go testem.
2. Napraw niewielki błąd fuse'a i wybierz uzasadnione testy regresyjne.
3. Wyjaśnij ścieżkę wywołania i uprawnienia dla konfiguracji vaulta, wskazując źródła.
4. Znajdź zweryfikowaną fabrykę na danej sieci i określ jej ABI oraz obsługiwane operacje.
5. Utwórz vault na forku przez istniejącą fabrykę; zweryfikuj role, opłaty i adresy.
6. Skonfiguruj przykład strategii i wykonaj testową ścieżkę deposit/withdraw.
7. Rozpoznaj niezgodny chain ID, ABI lub pakiet opłat i wskaż precyzyjną przyczynę.
8. Odróżnij test z upgrade'em fabryki od dowodu używalności istniejącego wdrożenia.

Mierzyć skuteczność, czas do pierwszego trafnego testu, liczbę interwencji człowieka, koszt/tokeny, liczbę zbędnych odczytów i jakość dowodów końcowych. Początkowy cel: co najmniej 80% poprawnie wykonanych zadań w kilku niezależnych powtórzeniach, wszystkie wykonywalne recepty zielone w CI i zero przypadków użycia wymyślonego adresu lub niepotwierdzonego ABI w planie wykonania.

Za ukończenie pierwszego etapu uznać sytuację, w której nowy agent, mając checkout, dostęp do potrzebnego RPC i poprawną konfigurację, odtwarza problem oraz przygotowuje zweryfikowane użycie istniejącej fabryki bez wiedzy przekazywanej poza repo.

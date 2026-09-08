# T08 — Wspólny punkt wejścia do repo

- **Status:** ready-for-commit
- **Data:** 2026-09-08 (Europe/Warsaw)
- **Agent/model:** Codex GPT-5
- **Baza:** `git rev-parse --short HEAD` = `e9e5c0c`, branch `feature/agents-support`
- **Zależności:** T01 (`87d86d8`), T04 (`7364631`), T05 (`024509c`)

## Zakres wykonany

Dodano 134-liniowy root `AGENTS.md` jako kanoniczny punkt wejścia dla contributorów i
agentów oraz czteroliniowy `CLAUDE.md`, który odsyła do wspólnego pliku zamiast kopiować
reguły. README linkuje `AGENTS.md`, a `.gitignore` dopuszcza wyłącznie root adapter Claude,
pozostawiając zagnieżdżone i prywatne pliki Claude ignorowane.

| Plik                        | Opis                                                                               |
| --------------------------- | ---------------------------------------------------------------------------------- |
| `AGENTS.md`                 | Cel, mapa repo, setup, testy, reguły Solidity, dowody, bezpieczeństwo i handoff.   |
| `CLAUDE.md`                 | Cienki adapter nakazujący odczyt kanonicznego `AGENTS.md`.                         |
| `.gitignore`                | Wyjątek `!/CLAUDE.md`; `.claude/` i zagnieżdżone `CLAUDE.md` pozostają ignorowane. |
| `README.md`                 | Widoczny link do instrukcji repo.                                                  |
| `agent-readiness/PLAN.md`   | Checkbox T08 zmieniony na `[x]`.                                                   |
| `agent-readiness/STATUS.md` | T07 uzgodnione z historią Git; T08 ustawione na `ready-for-commit`.                |

## Zawartość instrukcji

- Mapa istniejących katalogów kontraktów, testów, dokumentacji i helperów, w tym leżącego
  poza `contracts/factory/` pliku `contracts/managers/fee/FeeManagerFactory.sol`.
- Sprawdzone polecenia instalacji, builda, lokalnego testu fabryki, testu forkowego,
  formatowania i lintowania; brak nazw planowanych, ale jeszcze nieistniejących skryptów.
- Reguły doboru testów, wykrywania ukrytego RPC w `setUp()` i helperach oraz wymaganie
  niewakuowego testu regresyjnego.
- Reguły projektu dla `delegatecall`, ERC-7201, inicjalizacji, ról, jednostek, roundingu,
  kompatybilności storage/ABI, parametrów eventów i zakazu `via_ir = true`.
- Rozdzielenie dowodu z testu lokalnego, forka, przyszłego manifestu wdrożenia i odczytu
  on-chain; jawna informacja, że repo nie ma jeszcze registry/ABI/config/recipes.
- Zasady zachowania zmian użytkownika, sekretów i granic operacji on-chain. Plik nie wymaga
  ani nie ujawnia prywatnej pamięci, lokalnych notatek, adresów czy poświadczeń.

## Kroki

1. **Uzgodnienie stanu** — czysty branch `feature/agents-support`; T07 jest commitnięte jako
   `e9e5c0c`.
2. **Inwentaryzacja** — odczytano wymagania T08 i sekcję 3.1 planu, README, indeks docs,
   `foundry.toml`, mapę katalogów, vault README oraz reprezentatywne symbole routingu,
   inicjalizacji i fabryk.
3. **Implementacja** — utworzono `AGENTS.md` i `CLAUDE.md`, dodano root exception w
   `.gitignore`, link w README oraz zaktualizowano trackery.
4. **Odkrywalność klientów** — root `AGENTS.md` nie jest ignorowany; root `CLAUDE.md` nie jest
   ignorowany i odsyła do niego. `nested/CLAUDE.md` oraz `.claude/settings.json` nadal są
   ignorowane.
5. **Linki i ścieżki** — shellowy checker przeszedł po wszystkich lokalnych linkach w
   `AGENTS.md`, `CLAUDE.md` i README; dodatkowo sprawdzono wszystkie trzy wyróżnione ścieżki
   factory/test. Wynik: zero uszkodzonych linków.
6. **Polecenie lokalne** — `forge test --match-path test/factory/FusionFactory.t.sol`:
   66 passed, 0 failed, 0 skipped.
7. **Polecenie forkowe** — dokładne polecenie z instrukcji dla
   `FusionFactoryDaoFeePackagesForkTest.t.sol` na Ethereum, blok `23831825`: 8 passed,
   0 failed, 0 skipped.
8. **Kontrola dokumentów** — 134 linie `AGENTS.md`, 4 linie adaptera; Prettier zaakceptował
   oba pliki i README. `git diff --check` nie wykazał błędów whitespace.

## Weryfikacja kryteriów odbioru

| Kryterium                                    | Sprawdzenie                                                    | Wynik                                                      |
| -------------------------------------------- | -------------------------------------------------------------- | ---------------------------------------------------------- |
| Root instrukcja ma docelowy rozmiar          | `wc -l AGENTS.md`                                              | ✅ 134 linie, w zakresie około 100–150.                    |
| Codex/klient AGENTS znajduje instrukcje      | Root `AGENTS.md`; `git check-ignore --no-index`                | ✅ Plik istnieje i nie jest ignorowany.                    |
| Claude znajduje te same instrukcje           | Root `CLAUDE.md` i jego link; kontrola ignore                  | ✅ Adapter istnieje, nie jest ignorowany, brak duplikacji. |
| Prywatne adaptery pozostają prywatne         | `nested/CLAUDE.md`, `.claude/settings.json`                    | ✅ Oba nadal ignorowane.                                   |
| Dokument podaje tylko istniejące pliki       | Checker linków i jawne `test -f` dla wyróżnionych ścieżek      | ✅ Zero brakujących celów.                                 |
| Polecenie lokalne działa                     | `forge test --match-path test/factory/FusionFactory.t.sol`     | ✅ 66/66.                                                  |
| Polecenie forkowe działa                     | `forge test --match-path ...DaoFeePackagesForkTest.t.sol -vvv` | ✅ 8/8 na Ethereum, blok `23831825`.                       |
| Zakaz `via_ir` i reguły projektu są obecne   | Inspekcja sekcji `Solidity and protocol rules`                 | ✅ Jawny zakaz i wymagany sign-off ustawień kompilatora.   |
| Brak prywatnych danych i wymyślonych wdrożeń | Inspekcja treści; wyszukiwanie adresów i sekretów              | ✅ Tylko nazwy zmiennych i relatywne ścieżki.              |
| Format i whitespace są poprawne              | `prettier --check AGENTS.md CLAUDE.md README.md`; diff check   | ✅ Kontrole przeszły.                                      |

## Odstępstwa od planu

Brak. Instrukcje katalogowe dla factory, fuses i testów nie należą do T08 i zostaną dodane
przez dalsze zadania. Root dokument podaje bieżący brak registry/ABI/config/recipes zamiast
linkować nieistniejące artefakty.

## Follow-upy (poza zakresem, NIE zrobione)

- T09 doda szczegółową mapę architektury vaulta.
- T10–T13 dodadzą role, instrukcje katalogowe i katalog testów.
- T20–T32 zastąpią informację o braku wdrożeń linkami do zweryfikowanych manifestów, ABI i
  procedur fabryki; wtedy `AGENTS.md` wymaga aktualizacji.

## Blokada (tylko gdy status = blocked/partial)

Nie dotyczy.

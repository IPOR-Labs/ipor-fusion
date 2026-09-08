# T07 — Usunięcie niedziałającej komendy coverage

- **Status:** ready-for-commit
- **Data:** 2026-09-08 (Europe/Warsaw)
- **Agent/model:** Codex GPT-5
- **Baza:** `git rev-parse --short HEAD` = `f1a3be2`, branch `feature/agents-support`
- **Zależności:** T03 (committed `89f30eb`)

## Zakres wykonany

Usunięto skrypt npm `coverage:file`, ponieważ jego jedynym celem był nieistniejący plik
`tools/check_coverage.sh`. Nie dodawano zastępczego systemu coverage i nie zmieniano żadnych
testów ani konfiguracji Foundry.

| Plik                        | Opis                                                                |
| --------------------------- | ------------------------------------------------------------------- |
| `package.json`              | Usunięty martwy skrypt `coverage:file`.                             |
| `agent-readiness/PLAN.md`   | Checkbox T07 zmieniony na `[x]`.                                    |
| `agent-readiness/STATUS.md` | T06 uzgodnione z historią Git; T07 ustawione na `ready-for-commit`. |

## Kroki

1. **Uzgodnienie stanu** — czysty branch `feature/agents-support`; T06 jest commitnięte jako
   `f1a3be2`.
2. **Potwierdzenie braku implementacji** — `test -e tools/check_coverage.sh` zwróciło kod `1`;
   przegląd katalogu `tools/` nie znalazł alternatywnej implementacji.
3. **Reprodukcja błędu** — `npm run coverage:file` próbowało uruchomić
   `./tools/check_coverage.sh`, zakończyło się komunikatem `not found` i kodem `127`.
4. **Inwentaryzacja odwołań** — jedynym aktywnym odwołaniem wykonawczym był wpis w
   `package.json`. Trafienia w `agent-readiness/PLAN.md`, `ENVIRONMENT.md` oraz logach T00/T01
   opisują historyczny stan bazowy albo zakres T07, więc pozostają jako audytowalny zapis.
5. **Implementacja** — usunięto wyłącznie parę klucz/wartość `coverage:file` z `scripts`.
6. **Walidacja** — `package.json` parsuje się, `npm run` pokazuje siedem pozostałych skryptów
   i nie zawiera `coverage:file`; poza historycznym `agent-readiness/` nie pozostało żadne
   odwołanie do nieistniejącego pliku.
7. **Kontrola zakresu** — `package-lock.json` jest bez zmian, Prettier akceptuje `package.json`,
   a `git diff --check` nie wykazał błędów whitespace.

## Weryfikacja kryteriów odbioru

| Kryterium                                       | Sprawdzenie                                           | Wynik                                                    |
| ----------------------------------------------- | ----------------------------------------------------- | -------------------------------------------------------- |
| Implementacja coverage faktycznie nie istnieje  | `test -e tools/check_coverage.sh` i przegląd `tools/` | ✅ Brak pliku i alternatywnej implementacji.             |
| Martwa komenda została odtworzona               | `npm run coverage:file` przed zmianą                  | ✅ Exit `127`, `./tools/check_coverage.sh: not found`.   |
| Żaden skrypt npm nie wskazuje brakującego pliku | Parsowanie `package.json` oraz lista `npm run`        | ✅ Brak klucza `coverage:file`; pozostało siedem wpisów. |
| Brak aktywnych odwołań poza planem historycznym | `rg` z wyłączeniem `agent-readiness/**`               | ✅ Zero trafień.                                         |
| Lockfile nie został zmieniony                   | `git diff -- package-lock.json`                       | ✅ Brak diffu.                                           |
| Manifest i whitespace są poprawne               | `prettier --check package.json`; `git diff --check`   | ✅ Obie kontrole przeszły.                               |

## Odstępstwa od planu

Brak.

## Follow-upy (poza zakresem, NIE zrobione)

- Nie projektowano nowego systemu coverage, zgodnie z granicą T07.
- Historyczne wzmianki o `coverage:file` w materiałach `agent-readiness` pozostają celowo:
  dokumentują problem, który doprowadził do T07, i nie są instrukcjami wykonawczymi.

## Blokada (tylko gdy status = blocked/partial)

Nie dotyczy.

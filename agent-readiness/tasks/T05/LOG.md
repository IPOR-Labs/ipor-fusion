# T05 — Kontrola formatowania bez zapisu

- **Status:** ready-for-commit
- **Data:** 2026-09-08 (Europe/Warsaw)
- **Agent/model:** Codex GPT-5
- **Baza:** `git rev-parse --short HEAD` = `7364631`, branch `feature/agents-support`
- **Zależności:** T03 (committed `89f30eb`)

## Zakres wykonany

Dodano `npm run format:check`, które uruchamia bieżący Prettier z pluginem Solidity w trybie
`--check` dla tego samego zakresu co istniejące komendy zapisujące: `contracts/**/*.sol` i
`test/**/*.sol`. Komenda nie korzysta z `--write`. README rozdziela teraz kontrolę od
osobnej operacji `npm run prettier:all`, która nadal służy do stosowania formatowania.

| Plik                        | Opis                                                                         |
| --------------------------- | ---------------------------------------------------------------------------- |
| `package.json`              | Nowy skrypt `format:check` używa `prettier --check` dla kontraktów i testów. |
| `README.md`                 | Dokumentuje kontrolę bez zapisu i oddzielną komendę zapisującą.              |
| `agent-readiness/PLAN.md`   | Checkbox T05 zmieniony na `[x]`.                                             |
| `agent-readiness/STATUS.md` | T04 uzgodnione z historią Git; T05 ustawione na `ready-for-commit`.          |

## Kroki

1. **Uzgodnienie stanu** — czysty branch `feature/agents-support`; T04 jest commitnięte jako
   `7364631`.
2. **Inwentaryzacja** — istniejące skrypty `prettier:contracts` i `prettier:test` używają
   `--write` oraz obejmują wyłącznie Solidity w `contracts/` i `test/`; konfiguracja projektu
   ładuje Prettier `3.8.1` i `prettier-plugin-solidity` `2.2.1` z `package.json`.
3. **Implementacja** — dodano pojedynczy skrypt `format:check` z `--check` i opis użycia w
   README. Nie podłączano go do CI; to należy do T43.
4. **Próbka poprawna** — mały poprawnie sformatowany plik Solidity przeszedł kontrolę z
   kodem `0`; SHA-256 przed i po był identyczny.
5. **Próbka błędna** — celowo źle sformatowany plik Solidity został zgłoszony, a kontrola
   zakończyła się kodem `1`; SHA-256 przed i po był identyczny. Obie tymczasowe próbki
   usunięto po teście.
6. **Pełny zakres** — `npm run format:check` sprawdziło 933 pliki Solidity i zwróciło kod `1`,
   raportując zastane odchylenia m.in. w `contracts/factory/FusionFactory.sol`. Zbiorczy hash
   wszystkich plików Solidity był identyczny przed i po wykonaniu.
7. **Kontrola diffu** — sprawdzono format zmienionych plików użytkowych, poprawność JSON,
   whitespace oraz brak pozostałych plików-fixtures.

## Weryfikacja kryteriów odbioru

| Kryterium                            | Sprawdzenie                                           | Wynik                                                          |
| ------------------------------------ | ----------------------------------------------------- | -------------------------------------------------------------- |
| Poprawny plik przechodzi             | `prettier --check` na poprawnej próbce Solidity       | ✅ Exit `0`; plik niezmieniony.                                |
| Błędny plik daje niezerowy kod       | `prettier --check` na celowo błędnej próbce Solidity  | ✅ Exit `1`; plik wskazany w komunikacie.                      |
| Kontrola nie zapisuje                | SHA-256 próbek oraz całego drzewa Solidity przed i po | ✅ Wszystkie porównania identyczne.                            |
| Zastane błędy są raportowane         | `npm run format:check`                                | ✅ Exit `1` i lista istniejących odchyleń bez ich naprawy.     |
| Operacja zapisująca pozostaje osobna | Inspekcja `package.json` i README                     | ✅ `prettier:all` nadal używa istniejących skryptów `--write`. |
| T05 nie zmienia CI                   | `git diff -- .github/workflows`                       | ✅ Brak zmian; integracja należy do T43.                       |

## Odstępstwa od planu

Brak.

## Follow-upy (poza zakresem, NIE zrobione)

- T06 ujednolici wersje Prettiera i pluginu w pre-commit z `package.json`.
- Zastanych odchyleń formatowania nie naprawiono; należy je rozwiązywać świadomie bez
  masowego churnu niezwiązanego z T05.
- T43 podłączy `format:check` do CI po rozdzieleniu ścieżek z sekretami i bez sekretów.

## Blokada (tylko gdy status = blocked/partial)

Nie dotyczy.

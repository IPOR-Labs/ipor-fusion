# T06 — Spójne formatowanie w pre-commit

- **Status:** ready-for-commit
- **Data:** 2026-09-08 (Europe/Warsaw)
- **Agent/model:** Codex GPT-5
- **Baza:** `git rev-parse --short HEAD` = `024509c`, branch `feature/agents-support`
- **Zależności:** T05 (committed `024509c`)

## Zakres wykonany

Wersje formattera deklarowane przez hook pre-commit zostały wyrównane do dokładnych wersji
z `package.json`: Prettier `3.8.1` i `prettier-plugin-solidity` `2.2.1`. Nie zmieniono
wersji mirrora/harnessu pre-commit (`v4.0.0-alpha.8`), konfiguracji Prettiera ani zakresu
plików obsługiwanego przez hook.

| Plik                        | Opis                                                                |
| --------------------------- | ------------------------------------------------------------------- |
| `.pre-commit-config.yaml`   | Prettier `3.2.5` → `3.8.1`; plugin Solidity `1.3.1` → `2.2.1`.      |
| `agent-readiness/PLAN.md`   | Checkbox T06 zmieniony na `[x]`.                                    |
| `agent-readiness/STATUS.md` | T05 uzgodnione z historią Git; T06 ustawione na `ready-for-commit`. |

## Kroki

1. **Uzgodnienie stanu** — czysty branch `feature/agents-support`; T05 jest commitnięte jako
   `024509c`.
2. **Inwentaryzacja** — `package.json` przypina Prettier `3.8.1` i plugin Solidity `2.2.1`,
   podczas gdy pre-commit używał odpowiednio `3.2.5` i `1.3.1`.
3. **Implementacja** — zmieniono wyłącznie dwie pozycje `additional_dependencies` hooka
   Prettiera oraz trackery T06.
4. **Porównanie formatterów** — utworzono dwie identyczne, celowo źle sformatowane próbki
   Solidity. Jedną sformatowano lokalnym `./node_modules/.bin/prettier --write`, drugą przez
   `pipx run pre-commit run prettier --files ...`.
5. **Wynik** — izolowane środowisko hooka zostało utworzone z
   `prettier@3.8.1,prettier-plugin-solidity@2.2.1`; oba wyniki miały identyczny SHA-256:
   `16f714b8309751e2a4f4f8b56943efe06642f40b2603ebd8a1542083b94b8dff`.
6. **Sprzątnięcie i walidacja** — obie próbki usunięto. `pre-commit validate-config` oraz
   mechaniczne porównanie wersji z `package.json` przeszły; `git diff --check` nie wykazał
   błędów whitespace.

## Weryfikacja kryteriów odbioru

| Kryterium                             | Sprawdzenie                                                   | Wynik                                   |
| ------------------------------------- | ------------------------------------------------------------- | --------------------------------------- |
| Pre-commit używa wersji projektu      | Porównanie `additional_dependencies` z `package.json`         | ✅ `3.8.1` i `2.2.1` po obu stronach.   |
| Konfiguracja pre-commit jest poprawna | `pipx run pre-commit validate-config .pre-commit-config.yaml` | ✅ Exit `0`.                            |
| Obie ścieżki dają identyczny wynik    | Format lokalny i hook na dwóch kopiach tej samej próbki       | ✅ Identyczny SHA-256 `16f714b8…`.      |
| Nie sformatowano całego repo          | Inspekcja diffu i usunięcie dwóch tymczasowych fixtures       | ✅ Brak zmian w `contracts/` i `test/`. |
| Diff nie zawiera błędów whitespace    | `git diff --check`                                            | ✅ Brak błędów.                         |

## Odstępstwa od planu

Brak. `pre-commit` nie jest zainstalowany globalnie w VM, dlatego test uruchomiono przez
izolowane `pipx run pre-commit`; sam hook i jego zależności pochodzą z konfiguracji repo.

## Follow-upy (poza zakresem, NIE zrobione)

- Zastanych odchyleń formatowania raportowanych przez T05 nie poprawiano.
- Wersja mirrora `mirrors-prettier` pozostaje bez zmian; T06 dotyczy wyłącznie zgodności
  wersji Prettiera i pluginu z `package.json`.

## Blokada (tylko gdy status = blocked/partial)

Nie dotyczy.

# T04 — Przypięcie wersji Foundry

- **Status:** ready-for-commit
- **Data:** 2026-09-08 (Europe/Warsaw)
- **Agent/model:** Codex GPT-5
- **Baza:** `git rev-parse --short HEAD` = `89f30eb`, branch `feature/agents-support`
- **Zależności:** T03 (committed `89f30eb`)

## Zakres wykonany

Lokalna instrukcja i workflow CI używają teraz tej samej, sprawdzonej wersji Foundry:
`v1.7.1`. Wersja actiona instalującego Foundry pozostaje osobno przypięta do pełnego SHA
commita odpowiadającego tagowi `v1.9.1`; jego parametr `version` zmieniono z ruchomego
`stable` na release `v1.7.1`.

| Plik                                          | Opis                                                                                  |
| --------------------------------------------- | ------------------------------------------------------------------------------------- |
| `README.md`                                   | Podaje `v1.7.1`, komendę instalacji przez `foundryup` i kontrolę `forge --version`.   |
| `.github/workflows/smart-contracts-build.yml` | Instaluje dokładnie `v1.7.1` zamiast najnowszego wydania wskazywanego przez `stable`. |
| `agent-readiness/PLAN.md`                     | Checkbox T04 zmieniony na `[x]`.                                                      |
| `agent-readiness/STATUS.md`                   | T03 uzgodnione z historią Git; T04 ustawione na `ready-for-commit` z wynikiem testów. |

Nie zmieniono `foundry.toml`, wersji Solidity, EVM, optymalizatora ani innych parametrów
kompilacji.

## Kroki

1. **Uzgodnienie stanu** — czysty branch `feature/agents-support`; historia Git potwierdziła
   T03 jako commit `89f30eb`.
2. **Identyfikacja lokalnego toolchaina** — `forge --version` zwróciło `1.7.1`, commit
   `4072e48705af9d93e3c0f6e29e93b5e9a40caed8`, profil `dist`.
3. **Weryfikacja instalatora** — lokalne `foundryup --help` potwierdziło składnię
   `foundryup --install v1.2.3`; manifest użytego actiona `foundry-toolchain@v1.9.1`
   potwierdził, że `version` jest przekazywane do `foundryup --install` i obsługuje konkretne
   wydania.
4. **Implementacja** — README otrzymał instrukcję instalacji `v1.7.1`; CI przestało używać
   ruchomego aliasu `stable`.
5. **Build** — `forge build` zakończył się kodem `0`. Kompilacja była aktualna; Foundry
   wykonał lint i zgłosił wyłącznie zastane ostrzeżenia.
6. **Test fabryki** — `forge test --match-path test/factory/FusionFactory.t.sol` zakończył
   się wynikiem 66 passed, 0 failed, 0 skipped.
7. **Kontrola zakresu** — sprawdzono zgodność wersji w README i workflow, brak zmian
   `foundry.toml`, format zmienionych plików użytkowych oraz whitespace diffu.

## Weryfikacja kryteriów odbioru

| Kryterium                                     | Sprawdzenie                                                              | Wynik                                                     |
| --------------------------------------------- | ------------------------------------------------------------------------ | --------------------------------------------------------- |
| Lokalna wersja jest jawna i odtwarzalna       | `forge --version`; instrukcja `foundryup --install v1.7.1` w README      | ✅ Lokalnie działa Foundry `1.7.1` z commita `4072e487…`. |
| CI używa tej samej wersji                     | `version: v1.7.1` w kroku `Setup Foundry`                                | ✅ Alias `stable` zastąpiony konkretnym release'em.       |
| Parametry kompilatora pozostały bez zmian     | `git diff -- foundry.toml`                                               | ✅ Brak diffu.                                            |
| Build przechodzi                              | `forge build`                                                            | ✅ Exit `0`; wyłącznie zastane ostrzeżenia lintera.       |
| Reprezentatywny test fabryki przechodzi       | `forge test --match-path test/factory/FusionFactory.t.sol`               | ✅ 66 passed, 0 failed, 0 skipped.                        |
| Zmienione pliki użytkowe mają poprawny format | `prettier --check README.md .github/workflows/smart-contracts-build.yml` | ✅ Oba pliki przeszły.                                    |
| Diff nie zawiera błędów whitespace            | `git diff --check`                                                       | ✅ Brak błędów.                                           |

## Odstępstwa od planu

Brak.

## Follow-upy (poza zakresem, NIE zrobione)

- T05 doda niezmieniającą plików komendę `format:check`.
- T17 może wykorzystać `forge --version` do automatycznej diagnostyki odchylenia od
  przypiętego toolchaina.
- `agent-readiness/PLAN.md` i `agent-readiness/STATUS.md` mają zastane odchylenia od
  bieżącego formatowania Prettier; T04 ich nie formatuje, aby uniknąć masowego churnu.

## Blokada (tylko gdy status = blocked/partial)

Nie dotyczy.

# T02 — Działający przykład konfiguracji RPC

- **Status:** ready-for-commit
- **Data:** 2026-09-08 (Europe/Warsaw)
- **Agent/model:** Codex GPT-6
- **Baza:** `git rev-parse --short HEAD` = `87d86d8`, branch `feature/agents-support`
- **Zależności:** T01 (committed `87d86d8`)

## Zakres wykonany

Dodano `.env.example` z pięcioma pustymi zmiennymi RPC używanymi przez testy. Sekcja testów
w `README.md` podaje komendę utworzenia lokalnego `.env`, wyjaśnia wymaganie dostępu do archive
state dla przypiętych bloków i przypomina, że pliku z poświadczeniami nie wolno commitować.
Przy uzgadnianiu stanu planu oznaczono też T01 jako committed.

| Plik                        | Opis                                                                           |
| --------------------------- | ------------------------------------------------------------------------------ |
| `.env.example`              | Nowy bezpieczny szablon pięciu pustych URL-i RPC.                              |
| `README.md`                 | Instrukcja kopiowania szablonu i wymaganie archive state dla testów forkowych. |
| `agent-readiness/PLAN.md`   | Checkbox T02 zmieniony na `[x]`.                                               |
| `agent-readiness/STATUS.md` | T01 uzgodnione z historią Git; T02 ustawione na `ready-for-commit`.            |

## Kroki

1. **Uzgodnienie stanu** — `git status --short --branch` pokazał czyste drzewo na
   `feature/agents-support`; `git log -4 --oneline --decorate` potwierdził commit T01
   `87d86d8`.
2. **Sprawdzenie nazw RPC** — wyszukanie `vm.envString(...)` w `test/**/*.sol` wykazało pięć
   nazw: `ETHEREUM_PROVIDER_URL`, `ARBITRUM_PROVIDER_URL`, `BASE_PROVIDER_URL`,
   `TAC_PROVIDER_URL`, `INK_PROVIDER_URL`.
3. **Implementacja** — dodano `.env.example`, a w `README.md` komendę
   `cp .env.example .env`, opis archive state i zasadę niecommitowania poświadczeń.
4. **Weryfikacja nazw i wartości** — porównano posortowane nazwy z testów z lewymi stronami
   wpisów w `.env.example`; sprawdzono dokładnie 5 linii oraz puste wartości — exit `0`.
5. **Weryfikacja bezpieczeństwa i dokumentacji** — negatywny `rg` dla wartości i pól
   `PRIVATE|API_KEY|SECRET|MNEMONIC|SEED` nic nie znalazł; link wskazuje istniejący plik,
   a komenda kopiowania zadziałała w katalogu tymczasowym.
6. **Format i diff** — `./node_modules/.bin/prettier --check README.md` zwrócił
   `All matched files use Prettier code style!`; `git diff --check` zakończył się kodem `0`.

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md)                  | Sprawdzenie (komenda)                                                                                     | Wynik                                             |
| -------------------------------------- | --------------------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| Wszystkie nazwy odpowiadają testom     | Ekstrakcja `vm.envString` przez `rg` + porównanie z `cut -d= -f1 .env.example`                            | ✅ Identyczne zbiory pięciu nazw.                 |
| Szablon ma pięć pustych wartości       | `test "$(wc -l < .env.example)" -eq 5` + `awk -F= 'NF != 2 \|\| length($2) != 0 { exit 1 }' .env.example` | ✅ Pięć linii, każda wartość pusta.               |
| Brak sekretów i kluczy do podpisywania | Negatywny `rg -n '=.+\|PRIVATE\|API_KEY\|SECRET\|MNEMONIC\|SEED' .env.example`                            | ✅ Brak trafień.                                  |
| Link w README działa                   | `test -f .env.example`                                                                                    | ✅ Plik istnieje i nie jest ignorowany.           |
| Podana komenda działa                  | `cp .env.example "$scratch_dir/.env" && test -f "$scratch_dir/.env"` w `mktemp -d`                        | ✅ Kopia powstała bez dotykania lokalnego `.env`. |
| Dokument zachowuje format              | `./node_modules/.bin/prettier --check README.md` oraz `git diff --check`                                  | ✅ Obie kontrole przeszły.                        |

Nie uruchamiano testów kontraktów: T02 zmienia wyłącznie szablon środowiska i dokumentację,
a kryteria odbioru nie wymagają połączenia z RPC.

## Odstępstwa od planu

Brak.

## Follow-upy (poza zakresem, NIE zrobione)

- Automatyczna diagnostyka obecności i poprawności RPC należy do T17/T18.
- Rozdzielenie jawnych zestawów lokalnych i forkowych należy do T13–T16.

## Blokada (tylko gdy status = blocked/partial)

Nie dotyczy.

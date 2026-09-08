# T03 — Instalacja zgodna z lockfile

- **Status:** ready-for-commit
- **Data:** 2026-09-08 (Europe/Warsaw)
- **Agent/model:** Codex GPT-6
- **Baza:** `git rev-parse --short HEAD` = `6f0d8c8`, branch `feature/agents-support`
- **Zależności:** T02 (committed `6f0d8c8`)

## Zakres wykonany

README inicjalizuje teraz wszystkie submoduły rekurencyjnie na commitach zapisanych w Git,
a zależności Node instaluje przez `npm ci` z istniejącego `package-lock.json`. Ten sam tryb
instalacji zastąpił `npm install` w workflow budującym smart kontrakty. Nie zmieniono wersji
ani zawartości manifestów zależności.

| Plik                                          | Opis                                                                                                   |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `README.md`                                   | Powtarzalna instalacja: przypięte submoduły, `npm ci` i procedura uzupełnienia brakujących submodułów. |
| `.github/workflows/smart-contracts-build.yml` | Krok instalacji w CI używa `npm ci`.                                                                   |
| `agent-readiness/PLAN.md`                     | Checkbox T03 zmieniony na `[x]`.                                                                       |
| `agent-readiness/STATUS.md`                   | T02 uzgodnione z historią Git; T03 ustawione na `ready-for-commit`.                                    |

## Kroki

1. **Uzgodnienie stanu** — `git status --short --branch` pokazał czyste drzewo na
   `feature/agents-support`; historia Git potwierdziła T02 jako commit `6f0d8c8`.
2. **Inwentaryzacja instalacji** — `rg -n 'npm install|npm ci|submodule' README.md .github`
   znalazł `npm install` tylko w README i kroku Install workflow
   `.github/workflows/smart-contracts-build.yml`; `.gitmodules` definiuje dwa główne submoduły.
3. **Implementacja** — README otrzymał `git submodule update --init --recursive` i `npm ci`
   wraz z opisem lockfile oraz brakujących submodułów; CI zmieniono z `npm install` na `npm ci`.
4. **Czysta instalacja Node** — skopiowano wyłącznie `package.json` i `package-lock.json` do
   `mktemp -d`, wykonano tam `npm ci`, a następnie porównano SHA-256 lockfile przed i po.
   Wynik: 318 pakietów zainstalowanych, hash bez zmian
   `7295c08b119c50e785090cbd30aac028d3a3a98deab79d83c0c9d8668951ae7e`.
5. **Odtworzenie submodułów** — `git clone --no-hardlinks --no-recurse-submodules . <tmp>`
   utworzył zapisywalny świeży checkout z dwoma brakującymi submodułami. Uruchomienie w nim
   `git submodule update --init --recursive` zainicjalizowało oba główne i wszystkie zagnieżdżone;
   końcowy `git submodule status --recursive` nie wykazał braków ani commitów innych niż zapisane.
6. **Kontrola dokumentów i diffu** — `rg` nie znalazł pozostałego `npm install` w README ani
   workflow; `prettier --check README.md .github/workflows/smart-contracts-build.yml` oraz
   `git diff --check` przeszły.

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md)                      | Sprawdzenie (komenda)                                                                            | Wynik                                                                          |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------ | ----------------------------------------------------------- | ------------------------------------------------------------- |
| Czysta instalacja odtwarza zależności      | `npm ci` w katalogu z samymi `package.json` i `package-lock.json`                                | ✅ Zainstalowano 318 pakietów, exit `0`.                                       |
| Instalacja nie zmienia lockfile            | SHA-256 źródłowego i tymczasowego `package-lock.json` przed/po instalacji                        | ✅ Wszystkie hashe identyczne.                                                 |
| Submoduły są przypięte przez Git           | `git ls-tree HEAD lib/forge-std lib/foundry-random` + końcowy `git submodule status --recursive` | ✅ Główne i zagnieżdżone submoduły są na zapisanych commitach.                 |
| Brakujący submoduł ma działającą procedurę | Świeży klon bez submodułów → `git submodule update --init --recursive`                           | ✅ Liczba brakujących głównych submodułów: 2 → 0; zagnieżdżone również gotowe. |
| README i CI są spójne                      | `rg -n 'npm install                                                                              | npm ci                                                                         | git submodule update --init --recursive' README.md .github` | ✅ README i CI używają `npm ci`; `npm install` nie występuje. |
| Format i whitespace są poprawne            | `prettier --check README.md .github/workflows/smart-contracts-build.yml` + `git diff --check`    | ✅ Obie kontrole przeszły.                                                     |

`npm ci` zgłosił ostrzeżenie `EBADENGINE`, ponieważ VM ma Node 24/npm 11, a repo deklaruje
Node 20.17.0/npm 10.8.2. Instalacja mimo tego zakończyła się kodem `0`; rozbieżność była już
udokumentowana w `ENVIRONMENT.md`. Nie uruchamiano testów kontraktów, ponieważ T03 dotyczy
wyłącznie odtwarzania zależności.

## Odstępstwa od planu

Brak.

## Follow-upy (poza zakresem, NIE zrobione)

- `npm ci` raportuje 34 podatności w obecnym lockfile (16 low, 4 moderate, 12 high, 2 critical).
  T03 jawnie zabrania aktualizacji zależności, więc nie uruchamiano `npm audit fix`.
- Przypięcie wspólnej wersji Foundry należy do T04.

## Blokada (tylko gdy status = blocked/partial)

Nie dotyczy.

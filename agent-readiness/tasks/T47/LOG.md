# T47 — Odpowiedzialność za rejestr i proces wydania

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 przez Claude Code
- **Baza:** `562fea3`, branch `feature/agents-support`
- **Zależności:** T26, T45 (ready-for-commit)

## Zakres wykonany

- `CODEOWNERS` — zachowany domyślny wpis, dodane reguły dla `deployments/`,
  `abi/`, `catalog/`, `config/`, `docs/`, `tools/` i `.github/`; właściciele to
  istniejące konta `@mario-ipor` i `@pete-ipor`.
- `docs/release.md` — dziesięciopunktowa checklista zmiany tego, co repo twierdzi
  o wdrożeniu, z poleceniem przy każdym kroku, tabelą artefaktów pilotażu i
  zasadami zachowania historii.
- `.gitignore`, `docs/README.md` — wyjątek i wpis w indeksie.

## Kroki

1. **Właściciele z repozytorium** — odczytany istniejący `CODEOWNERS`; nie dopisano żadnego nowego konta.
2. **Checklista z faktycznie przejściej ścieżki** — każdy krok odpowiada temu, co zrobiono w T20–T36; tabela mapuje krok na powstały artefakt.
3. **Kontrola odnośników** — `npm run validate:docs` (20 plików, 228 lokalnych linków).

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| Wskazani istniejący, właściwi właściciele w `CODEOWNERS` | tylko `@mario-ipor` i `@pete-ipor`, obecni w pliku przed zmianą | ✅ |
| Opisana aktualizacja ABI, manifestów, historii i recept przy wydaniu | kroki 2, 3, 6, 8 i sekcja „Keeping history" | ✅ |
| Checklistę da się przejść na pilotażowym przykładzie | tabela „Walking it on the pilot" z artefaktami T20–T36; każdy link istnieje | ✅ |
| Właściciele nie są wymyślonymi kontami | żadne nowe konto nie zostało dodane | ✅ |
| Dokumenty nie sugerują, że monitoring zastępuje review | akapit „Monitoring does not replace review" | ✅ |

## Odstępstwa od planu

- Nie da się z tego środowiska sprawdzić, czy `CODEOWNERS` jest egzekwowany
  (wymaga ustawienia „require review from Code Owners" w GitHub). To ustawienie
  repozytorium, wskazane wcześniej w `docs/ci.md`.

## Follow-upy (poza zakresem, NIE zrobione)

- Potwierdzenie w ustawieniach GitHub, że review od CODEOWNERS jest wymagany.
- Osobna checklista dla wydania kontraktów (ten dokument dotyczy rejestru).

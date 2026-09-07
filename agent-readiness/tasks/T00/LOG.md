# T00 — Pomiar bazowy przed usprawnieniami

- **Status:** partial
- **Data:** 2026-09-07 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 (1M context) przez Claude Code
- **Baza:** `git rev-parse --short HEAD` = `a81cd22`, branch `feature/agents-support`
- **Zależności:** brak

## Zakres wykonany

Powstał katalog `evals/agent-readiness/` z definicją zestawu pomiarowego i z kartą
pomiaru. Osiem zadań z sekcji 10 PLAN.md jest zapisanych formalnie wraz z warunkami
porównywalności, metrykami i regułami dyskwalifikacji. Warunki przebiegu 1 są
zweryfikowane na tej maszynie i wpisane; **samych wyników nie ma**, bo prawidłowy
pomiar wymaga sesji bez prywatnej pamięci, a tej sesji nie da się uruchomić z jej
własnego wnętrza. Runnera — zgodnie z zakresem — nie budowano.

- `evals/agent-readiness/tasks.json` — nowy: 8 zadań (E1–E8) z promptem, kotwicami w
  repo, kryteriami zaliczenia, wymaganym RPC/narzędziami; do tego `run_conditions`
  (w tym wymóg `memory_mode: none`), `scoring` z sześcioma metrykami i celami z sekcji
  10 oraz `fixtures` przypinane w przebiegu 1.
- `evals/agent-readiness/baseline.md` — nowy: procedura przebiegu, tabela fixture'ów,
  warunki przebiegu 1 (commit, model, narzędzia, limit pracy, sieć, tryb pamięci),
  pusta tabela wyników E1–E8, lista braków dostępu i stan wyjściowy repo na `a81cd22`.

## Kroki

1. **Rekonesans stanu** — `git status --short`, `git log --oneline --all | grep -E "\bT[0-9]{2}\b"` → drzewo czyste, żaden `Txx` nie jest jeszcze w historii; `agent-readiness/` jest w `a81cd22`.
2. **Sprawdzenie, czy `evals/` nie jest ignorowany** — `git check-ignore -v evals/agent-readiness/tasks.json` → exit 1 (nieignorowany), więc katalog da się dodać do commita.
3. **Przypięcie kotwic w repo (bez zmyślania)** — `grep -rn "UnsupportedFuse" contracts/` → deklaracja `PlasmaVault.sol:238` i dwa realne `revert` w ścieżce wykonania (`:401`, `:1233`); `grep -n "function " contracts/factory/FusionFactory.sol` → wejście tworzące to `clone` / `cloneSupervised`. Te fakty stały się kotwicami E1 i E4/E5.
4. **Ustalenie trybu „sesja bez prywatnej pamięci"** — `claude --help` → flaga `--bare` pomija auto-memory i auto-discovery `CLAUDE.md`, ale wymaga `ANTHROPIC_API_KEY`/`apiKeyHelper`; sprawdzenie zmiennych (tylko nazwy) → `ANTHROPIC_API_KEY` i `CLAUDE_CODE_OAUTH_TOKEN` puste. Zapisane jako brak dostępu, z wariantem zapasowym (osobny `HOME`).
5. **Napisanie `tasks.json`** — walidacja `python3 -m json.tool` → OK; skrypt sprawdzający → `tasks: 8 ['E1'..'E8']`, `broken anchors: none`, `undeclared fixture refs: none`.
6. **Napisanie `baseline.md`** — link `[tasks.json](tasks.json)` sprawdzony → OK, brak zepsutych odnośników.
7. **Weryfikacja twierdzeń o stanie wyjściowym repo** — brak `AGENTS.md`, `.env.example`, `docs/README.md`, `deployments/`, `abi/`, `catalog/`; `grep -n "profile.ci" foundry.toml` → brak; lista skryptów npm → `coverage:file`, `prettier:*`, `solhint:*` (brak `test:*`, `agent:*`, `format:check`).

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| Osiem zadań z sekcji 10 zdefiniowanych w `evals/agent-readiness/tasks.json` | `python3 -m json.tool …` + skrypt liczący zadania i kotwice | ✅ 8 zadań E1–E8, wszystkie kotwice istnieją |
| Warunki zapisane w `baseline.md` | odczyt pliku; fakty toolchainu z `forge --version`, `node -v`, `npm -v` | ✅ commit, model, narzędzia, limit pracy, sieć, tryb pamięci |
| Wynik podaje rezultaty | — | ❌ brak — pomiaru nie wykonano (patrz Blokada) |
| Wynik podaje braki dostępu | sprawdzenie `--bare`/kluczy API, `.env` (nazwy), `gh`, TAC | ✅ pięć konkretnych braków wypisanych w `baseline.md` |
| Do porównania samego repo używać sesji bez prywatnej pamięci; nie nazywać tego pomiarem sprzed konfiguracji pamięci | zapis reguły w `run_conditions.memory_mode` i w sekcji „How a run is made" | ✅ wymóg zapisany i uzasadniony; przebieg z pamięcią jest osobnym przebiegiem |
| Nie budować runnera | — | ✅ brak kodu wykonawczego, `results_file` wskazuje na kartę ręczną |

## Odstępstwa od planu

- Zadanie zamknięte jako **partial**, nie `ready-for-commit`: definicja zestawu i warunki
  są kompletne, brakuje pierwszego wyniku. Checkbox T00 w PLAN.md pozostaje `[ ]`,
  pod nim dopisana `**Blokada:**`.
- Fixture'y (sieć pilotażu, adres fabryki, wstrzyknięty błąd fuse'a, przypadek
  niezgodności, para testów do E8) są `null` z procedurą przypięcia w przebiegu 1,
  zamiast wartości zmyślonych. E4/E5 zależą od adresu wdrożenia, którego nie wolno
  zgadywać, a T20 (źródło adresów) jest dopiero przed nami.
- `evals/agent-readiness/` jest po angielsku — to artefakt zespołowy w repo, nie plik
  procesowy Pete'a.

## Follow-upy (poza zakresem, NIE zrobione)

- Przebieg 1 zestawu: osiem sesji `--bare`, wypełnienie tabeli wyników i przypięcie
  fixture'ów. Naturalnie łączy się z T48 (benchmark vs baseline).
- `ANTHROPIC_API_KEY`/`apiKeyHelper` dla trybu `--bare` albo uzgodniony wariant
  z osobnym `HOME` — bez tego pomiar nie ruszy z tej maszyny.
- `TAC_PROVIDER_URL` jest puste; dopóki tak jest, TAC nie może być siecią pilotażu.

## Blokada (tylko gdy status = blocked/partial)

Brakuje **pierwszego wyniku pomiaru**. Odbiór wymaga sesji bez prywatnej pamięci, a ta
sesja ma załadowaną prywatną wiki (`~/.claude/knowledge`) i globalny `CLAUDE.md` —
pomiar wykonany tutaj byłby niezgodny z własnym kryterium i zafałszowałby punkt
odniesienia. Dodatkowo `claude --bare` wymaga `ANTHROPIC_API_KEY` lub `apiKeyHelper`,
a w tym środowisku żaden nie jest ustawiony.

Odblokuje to: Pete uruchamia osiem sesji bez prywatnej pamięci na commicie podanym
w warunkach, przypina fixture'y i wpisuje wyniki do tabeli w `baseline.md`. Wtedy T00
domyka się osobnym, drobnym commitem i checkbox idzie na `[x]`.

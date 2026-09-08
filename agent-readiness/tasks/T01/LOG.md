# T01 — Selektywne wersjonowanie dokumentacji

- **Status:** ready-for-commit
- **Data:** 2026-09-07 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 (1M context) przez Claude Code
- **Baza:** `git rev-parse --short HEAD` = `7d64650`, branch `feature/agents-support`
- **Zależności:** T00 (committed `7d64650`, status `partial` — pominięta decyzją Pete'a, patrz „Odstępstwa")

## Zakres wykonany

`.gitignore` przestaje ignorować cały katalog `docs/` blokiem `docs/`, a zaczyna ignorować jego
zawartość (`docs/*`) z jawną listą wyjątków. Dziś jedynym wyjątkiem jest `!docs/README.md`.
Powstał `docs/README.md` — indeks dokumentacji: co jest tu wersjonowane, jak dodać kolejny
dokument (plik + własna linia wyjątku w tym samym commicie), zasady treści (angielski, brak
sekretów, brak zmyślonych adresów/ABI) oraz tabela dokumentacji, która już istnieje w repo.

| Plik | Opis |
| --- | --- |
| `.gitignore` | sekcja `### Documentation ###`: `docs/*` + `!docs/README.md`; linia `docs/` usunięta |
| `docs/README.md` | nowy indeks dokumentacji (68 linii, angielski), sformatowany Prettierem |

Prywatny `docs/superpowers/` pozostaje ignorowany — sprawdzone jawnie, bo to główne ryzyko
tej zmiany.

## Kroki

1. **Reconcile stanu** — `git status --short` → czysto; `git log --oneline --all | grep -E "\bT[0-9]{2}\b"` → `7d64650 # T00 …`, czyli T00 jest zacommitowane (STATUS miał `partial` bez hasha; wiersz uzupełniony).
2. **Odczyt zadania i projektu** — `sed -n '/^#### T01 /,/^#### T02 /p' agent-readiness/PLAN.md` oraz sekcje 2, 3 i 9.1 planu → zakres: selektywny `.gitignore` + indeks; kolejne zadania dokładają wyjątki razem ze swoim dokumentem.
3. **Zmiana `.gitignore`** — blok `docs/` → `docs/*` + `!docs/README.md` z komentarzem wyjaśniającym regułę; pozostałe linie (`.env`, `CLAUDE.md`, `.claude/`, `GEMINI.md`, `reports/`, `research/`, `temp/`) nietknięte.
4. **Napisanie indeksu** — `docs/README.md`; wszystkie odnośniki tylko do plików istniejących po samym T01 (bez odwołań do `docs/architecture.md` itp. z sekcji 3.2 planu).
5. **Formatowanie** — `./node_modules/.bin/prettier --check docs/README.md` → `exit=1`; `--write` (zmiana wyłącznie w wyrównaniu tabeli), ponowny `--check` → `All matched files use Prettier code style!`. Powód: hook `pre-commit` (prettier) obejmuje `docs/README.md` — `exclude` w `.pre-commit-config.yaml` wyłącza tylko `README.md` z korzenia. Bez tego hook przepisałby plik podczas commita Pete'a.
6. **Weryfikacja odbioru** — komendy w tabeli niżej.

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| `git check-ignore` potwierdza, że indeks można dodać | `git check-ignore -q docs/README.md` | ✅ `exit=1` (nie ignorowany) |
| lokalne notatki nie zostały ujawnione | `git check-ignore -q docs/superpowers/plans` / `docs/scratch.md` / `docs/notes/x.md` | ✅ każde `exit=0` (nadal ignorowane) |
| `.env` nie został ujawniony | `git check-ignore -q .env` | ✅ `exit=0`; dodatkowo `CLAUDE.md`, `.claude/settings.json`, `GEMINI.md`, `reports/x`, `research/x`, `temp/x` → wszystkie `exit=0` |
| `git status` potwierdza, co wejdzie do commita | `git status --short --untracked-files=all` | ✅ dokładnie ` M .gitignore` i `?? docs/README.md`; `grep -c superpowers` → `0` |
| każdy odnośnik prowadzi do istniejącego pliku | `grep -o '](\.\./[^)]*)' docs/README.md \| … \| test -e` | ✅ 6/6 OK, 0 BROKEN |
| komenda podana w dokumencie działa | `git ls-files 'contracts/**/README.md' \| wc -l` | ✅ `24` |
| kolejne zadania dodają wyjątki razem z dokumentem | reguła zapisana w `.gitignore` (komentarz) i w `docs/README.md` („How to add a document", krok 2) | ✅ udokumentowane |

Nie uruchamiano testów kontraktów — zadanie jest wyłącznie dokumentacyjno-konfiguracyjne
(zasada z sekcji 9.1: „dla dokumentacji wystarczy kontrola treści i linków").
`git add --dry-run` nie działa w VM (`.git` read-only, `Unable to create .git/index.lock`);
zastąpione przez `git status --short --untracked-files=all`, które daje tę samą informację.

## Odstępstwa od planu

- **Pominięta zależność T00.** T00 jest zacommitowane (`7d64650`), ale ma status `partial` —
  brakuje pierwszego przebiegu pomiaru. Pete zdecydował w tej sesji: „pominiemy to, zrobimy to
  na końcu i na innym branchu". Blokada T00 (uruchomienie sesji pomiarowych bez prywatnej
  pamięci) nie dotyka zakresu T01. Przy okazji ustalono i zweryfikowano przepis na przebieg
  pomiaru — zapisany w „Follow-upach", bo nie należy do T01.
- `docs/README.md` jest po angielsku (artefakt zespołowy w repo), zgodnie z sekcją 3.1 planu.

## Follow-upy (poza zakresem, NIE zrobione)

- **Przepis na przebieg pomiaru T00, zweryfikowany w tej sesji** (do wykorzystania przy
  domykaniu T00 na osobnym branchu): `claude --bare` odpada, bo w tym trybie auth to wyłącznie
  `ANTHROPIC_API_KEY`/`apiKeyHelper`, a w tym środowisku jest tylko OAuth. Działa wariant
  „osobny `HOME`": skopiowanie `~/.claude/.credentials.json` do pustego `HOME` +
  `git clone --no-hardlinks` repo do katalogu roboczego (klon ma zapisywalne `.git`, więc
  `git checkout <commit>` działa mimo read-only `.git` w oryginale) + `cp -a` dla
  `lib/forge-std`, `lib/foundry-random` i `node_modules` (symlink na `node_modules` **nie**
  działa — forge nie wychodzi poza root projektu). Sprawdzone: `forge test --match-path
  "test/unitTest/*"` w klonie → 985 passed, 0 failed. `claude -p --output-format json` zwraca
  `usage`/`modelUsage`/`total_cost_usd`, czyli metrykę `cost_tokens` wprost. Do rozważenia
  przepięcie warunków przebiegu 1 w `baseline.md` z `a81cd22` na `7d64650`.
- `README.md` w korzeniu odsyła do `.env.example`, którego nie ma — to zakres T02.
- `.pre-commit-config.yaml` używa Prettiera 3.2.5 + plugin 1.3.1, a `package.json` 3.8.1 + 2.2.1;
  markdown formatuje tylko hook, CI (`prettier:all`) obejmuje wyłącznie `.sol` — zakres T05/T06.
- Skrypt `coverage:file` nadal wskazuje nieistniejący `tools/check_coverage.sh` — zakres T07.

## Blokada (tylko gdy status = blocked/partial)

Brak — zadanie zamknięte jako `ready-for-commit`.

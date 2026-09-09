# T48 — Powtarzalny benchmark i porównanie z baseline

- **Status:** ready-for-commit
- **Data:** 2026-09-09 (Europe/Warsaw)
- **Agent/model:** Claude Opus 5 przez Claude Code
- **Baza:** `562fea3`, branch `feature/agents-support`
- **Zależności:** T00 (`7d64650`, partial), T19 (`8fbf2d2`), T32, T36, T38 (ready-for-commit)

## Zakres wykonany

- `evals/agent-readiness/results.schema.json` — rekord przebiegu: warunki
  (commit, model, narzędzia, budżet, dostęp do sieci, tryb pamięci, powtórzenia),
  przypięte fixture'y i wynik każdego z ośmiu zadań z metrykami.
- `tools/evals-report.mjs` (`evals:report`) — walidacja rekordów i raport:
  skuteczność (bez `blocked` w mianowniku), interwencje, koszt, mediana czasu do
  pierwszego istotnego testu, jakość dowodów, hard faile oraz porównanie dwóch
  przebiegów z odmową przy zmienionych warunkach.
- `tools/test-evals-report.mjs` — 10 testów na syntetycznych rekordach.
- `evals/agent-readiness/baseline.md` — sekcja „Recording a run as data".
- `.github/workflows/pr-checks.yml` — `evals:report:test` w jobie bez sekretów.
- `package.json` — `evals:report`, `evals:report:test`.

## Kroki

1. **Warunki zgodne z T00** — pola wymagane przez schemat odpowiadają `run_conditions.required_fields` z `tasks.json`; `memoryMode: "private-memory"` jest zapisywany jawnie i nigdy nie uchodzi za baseline repozytorium.
2. **Rozróżnienie braku dostępu od porażki** — `blocked` wymaga podania brakującego warunku i wypada z mianownika skuteczności.
3. **Widoczna zmiana modelu/pamięci/środowiska** — porównanie odmawia, gdy różni się cokolwiek poza commitem, i wypisuje różniące się pola.
4. **Testy i pusty stan** — 10/10; `npm run evals:report` bez danych mówi wprost, że nic nie zmierzono. Szczegóły w [`runs.txt`](runs.txt).

## Weryfikacja kryteriów odbioru

| Kryterium (z PLAN.md) | Sprawdzenie (komenda) | Wynik |
| --- | --- | --- |
| Runner albo udokumentowany protokół oceny ośmiu zadań | protokół z T00 w `baseline.md` + maszynowy rekord i raport (`evals:report`) | ✅ |
| Walidacja wyników | schemat + kontrole: brak zadania, duplikat, zadanie spoza suity, `blocked` bez przyczyny, wartości poza zakresem | ✅ |
| Raport pokazuje skuteczność, interwencje, czas i koszt | test „a run reports success, interventions, time and cost" | ✅ |
| Odróżnia brak dostępu od porażki rozwiązania | `blocked` z `blockedBy`, poza mianownikiem; osobno raportowane | ✅ |
| Zmiana modelu, pamięci lub środowiska widoczna, nie przypisana repo | `comparable: false` + lista zmienionych pól i komunikat | ✅ |
| Warunki zgodne z T00 | te same pola wymagane co w `tasks.json` | ✅ |
| Raport po zmianach w `evals/agent-readiness/` | `--compare <runId>` liczy delty skuteczności, interwencji i kosztu | ⚠️ narzędzie gotowe, brak danych do porównania |

## Odstępstwa od planu

- **Nie wykonano pomiaru.** Wymaga sesji bez prywatnej pamięci (`claude --bare`
  potrzebuje klucza API, którego to środowisko nie ma) — to nadal otwarta część
  T00, odłożona decyzją Pete'a na koniec i na osobny branch. To zadanie dostarcza
  narzędzie i format, nie wyniki.

## Follow-upy (poza zakresem, NIE zrobione)

- Przeprowadzenie run 1 (baseline) i run 2 (po tej serii) na osobnym branchu, z
  przypięciem fixture'ów w `baseline.md`.
- Ewentualny automatyczny runner — dziś operator prowadzi sesje ręcznie, zgodnie
  z protokołem T00.

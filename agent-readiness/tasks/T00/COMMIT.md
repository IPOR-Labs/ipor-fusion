# T00 — commit do wykonania ręcznie na hoście

## Komunikat

```
docs(agents): T00 record readiness baseline

Add evals/agent-readiness/ with the eight measurement tasks from PLAN.md
section 10 (tasks.json: prompts, repo anchors, pass criteria, six metrics,
targets, comparability conditions) and the measurement card baseline.md
(procedure, fixtures, verified run-1 conditions, access gaps, repo starting
state at a81cd22). No runner, per scope.

Verified: tasks.json parses, all repo anchors exist, baseline.md links
resolve, and every claim about the repo's starting state was re-checked.
The first measurement result is missing on purpose - it requires a session
without private memory, so T00 stays partial and its checkbox stays [ ].
```

Ten sam tekst jest w `agent-readiness/tasks/T00/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `evals/agent-readiness/tasks.json` | nowy — definicja 8 zadań E1–E8, metryki, cele, warunki |
| `evals/agent-readiness/baseline.md` | nowy — karta pomiaru: procedura, fixture'y, warunki, braki dostępu |
| `agent-readiness/PLAN.md` | dopisana linia `**Blokada:**` pod T00; checkbox zostaje `[ ]` |
| `agent-readiness/STATUS.md` | wiersz T00 → `partial` |
| `agent-readiness/tasks/T00/LOG.md` | nowy |
| `agent-readiness/tasks/T00/COMMIT.md` | nowy |
| `agent-readiness/tasks/T00/commit-message.txt` | nowy |

## Pliki w `git status`, które NIE należą do tego commita

brak — drzewo było czyste przed zadaniem.

## Komendy dla hosta

```bash
cd /Users/piotrrzonsowski/repos/ipor-fusion
git add evals/agent-readiness/tasks.json
git add evals/agent-readiness/baseline.md
git add agent-readiness/PLAN.md
git add agent-readiness/STATUS.md
git add agent-readiness/tasks/T00/LOG.md
git add agent-readiness/tasks/T00/COMMIT.md
git add agent-readiness/tasks/T00/commit-message.txt
git status --short          # sprawdź, że staged są tylko pliki z tabeli
git commit -F agent-readiness/tasks/T00/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T00 na `committed <hash>`
(status merytoryczny zostaje `partial` do czasu wykonania przebiegu 1).

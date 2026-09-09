# T38 — commit do wykonania ręcznie na hoście

## Komunikat

```
docs(debugging): T38 add factory and vault troubleshooting

Add docs/troubleshooting.md: the concrete errors this repository's tools and
tests actually produce — RPC and archive state, implementation and version drift,
an ABI that no longer matches the deployed fuse, missing roles, fee package
disagreement, substrates, market limits, price sources, and the four transaction
outcomes — each with the command that confirms the cause.

Every symptom comes from a real run recorded in the readiness tasks, and every
diagnostic command was executed against the pinned Ethereum block or a local
fork. The page reports causes and never prescribes a fix.
```

Ten sam tekst jest w `agent-readiness/tasks/T38/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/PLAN.md` | checkbox T38 → `[x]` |
| `agent-readiness/STATUS.md` | wiersz T38 → ready-for-commit |
| `agent-readiness/tasks/T38/*` | nowe — LOG, COMMIT, komunikat, runs |
| `docs/troubleshooting.md` | nowy — diagnostyka |
| `docs/README.md` | zmieniony — indeks i lista wyjątków |
| `.gitignore` | zmieniony — `!docs/troubleshooting.md` |

## Pliki w `git status`, które NIE należą do tego commita

- zmiany T25–T37. `.gitignore` i `docs/README.md` są wspólne z wcześniejszymi
  zadaniami serii.

## Komendy dla hosta

```bash
cd ~/repos/ipor-fusion
git add agent-readiness/PLAN.md agent-readiness/STATUS.md agent-readiness/tasks/T38/
git add docs/troubleshooting.md docs/README.md .gitignore
git status --short
git commit -F agent-readiness/tasks/T38/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T38 na `committed <hash>`.

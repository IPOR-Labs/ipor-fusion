# T26 — commit do wykonania ręcznie na hoście

## Komunikat

```
chore(deployments): T26 verify the pilot factory manifest

Promote the Ethereum FusionFactory entry from candidate to verified, backed by a
secret-free report under deployments/reports/ that pins block 25937526 and its
hash, the toolchain, the inspector script hash and the compatibility test hash.

The report records reproduced identity reads, runtime code at all sixteen
component addresses and the passing deployed-usage test; the manifest gains the
runtime hashes, reported version, dependencies and the verification record.

Verified with validate:deployments (including a rejected verified entry with a
missing proof field), the inspector and fork test on block 25937526.
```

Ten sam tekst jest w `agent-readiness/tasks/T26/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/PLAN.md` | checkbox T26 → `[x]` |
| `agent-readiness/STATUS.md` | wiersz T26 → ready-for-commit |
| `agent-readiness/tasks/T26/LOG.md` | nowy |
| `agent-readiness/tasks/T26/COMMIT.md` | nowy |
| `agent-readiness/tasks/T26/commit-message.txt` | nowy |
| `agent-readiness/tasks/T26/runs.txt` | nowy — wyjścia weryfikacji |
| `deployments/reports/ethereum-fusion-factory-cd05909c-25937526.json` | nowy — raport weryfikacji |
| `deployments/1/factories.json` | zmieniony — `verified`, hashe, wersja, zależności, `verification` |
| `.gitignore` | zmieniony — wyjątek `!deployments/reports/` |
| `docs/deployments.md` | zmieniony — sekcja „Verification record" i status pilotażu |

## Pliki w `git status`, które NIE należą do tego commita

- `config/test-suites.json`, `docs/testing.md`, `test/AGENTS.md`,
  `test/deployed-factories/` — zmiany T25 (jeszcze niezacommitowane).
- **Uwaga:** `agent-readiness/PLAN.md`, `agent-readiness/STATUS.md` i
  `docs/deployments.md` zawierają zmiany T25 **i** T26 w jednym pliku. Jeśli
  commitujesz zadania osobno, commituj T25 przed T26 i licz się z tym, że te
  trzy pliki wejdą do commita T25 razem ze zmianami T26 (albo zrób jeden commit
  na całą serię).

## Komendy dla hosta

```bash
cd ~/repos/ipor-fusion
git add agent-readiness/PLAN.md agent-readiness/STATUS.md agent-readiness/tasks/T26/
git add .gitignore docs/deployments.md deployments/1/factories.json
git add deployments/reports/ethereum-fusion-factory-cd05909c-25937526.json
git status --short          # sprawdź, że staged są tylko pliki z tabeli
git commit -F agent-readiness/tasks/T26/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T26 na `committed <hash>`.

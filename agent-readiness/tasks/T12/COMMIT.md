# T12 — commit do wykonania ręcznie na hoście

## Komunikat

```
docs(fuses): T12 add fuse development guidance

Add scoped instructions for changing action fuses, balance fuses, substrates and
reward fuses, using the ERC-4626 integration as the worked example.

Document the delegatecall call path from execute(), the full-replacement
semantics of substrate grants, WAD valuation through the price oracle, and the
ABI-signature coupling between enter/exit structs and their call sites.

Verified by walking ERC-4626 from source to test: forge build, then
forge test --match-path 'test/fuses/erc4626/*' with 23 passed, 0 failed.
```

Ten sam tekst jest w `agent-readiness/tasks/T12/commit-message.txt`.

## Pliki należące do tego commita

| Plik                                               | Zmiana                                                    |
| -------------------------------------------------- | --------------------------------------------------------- |
| `contracts/fuses/AGENTS.md`                        | nowy — instrukcje dla zmian w fuse'ach i rewards fuse'ach |
| `agent-readiness/PLAN.md`                          | checkbox T12 → `[x]`                                      |
| `agent-readiness/STATUS.md`                        | T11 → committed `a92080a`; T12 → ready-for-commit         |
| `agent-readiness/tasks/T12/LOG.md`                 | nowy — przebieg i wyniki weryfikacji                      |
| `agent-readiness/tasks/T12/COMMIT.md`              | nowy — ta instrukcja                                      |
| `agent-readiness/tasks/T12/commit-message.txt`     | nowy — gotowy komunikat commita                           |
| `agent-readiness/tasks/T12/forge-test-erc4626.txt` | nowy — wyjście `forge test` dla ERC-4626                  |

## Pliki w `git status`, które NIE należą do tego commita

Brak — drzewo było czyste po commicie T11 (`a92080a`).

## Komendy dla hosta

```bash
cd /Users/piotrrzonsowski/repos/ipor-fusion
git add contracts/fuses/AGENTS.md
git add agent-readiness/PLAN.md
git add agent-readiness/STATUS.md
git add agent-readiness/tasks/T12/LOG.md
git add agent-readiness/tasks/T12/COMMIT.md
git add agent-readiness/tasks/T12/commit-message.txt
git add agent-readiness/tasks/T12/forge-test-erc4626.txt
git status --short          # sprawdź, że staged są tylko pliki z tabeli
git commit -F agent-readiness/tasks/T12/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T12 na `committed <hash>` (albo zrobi to
następny agent w kroku 0 skilla).

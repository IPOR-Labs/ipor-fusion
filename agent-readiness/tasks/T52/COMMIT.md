# T52 — commit do wykonania ręcznie na hoście

## Komunikat

```
feat(mcp): T52 expose verified deployment inspection

Add a stdio MCP server with exactly two read-only tools, list_deployments and
inspect_factory, both reading the repository's own manifests and running the same
inspector the CLI runs. There is no second registry and no second implementation.

The existing ipor-fusion MCP server stays the discovery source; it does not serve
this repository's manifests, verification reports or compatibility tests, which is
what these two tools add.

Nothing here can sign, send or write: a test asserts the tool list is exactly
those two, and another asserts that the MCP call and the CLI return structurally
identical JSON for the same chain, deployment, block and caller.
```

Ten sam tekst jest w `agent-readiness/tasks/T52/commit-message.txt`.

## Pliki należące do tego commita

| Plik | Zmiana |
| --- | --- |
| `agent-readiness/PLAN.md` | checkbox T52 → `[x]` |
| `agent-readiness/STATUS.md` | wiersz T52 → ready-for-commit |
| `agent-readiness/tasks/T52/*` | nowe — LOG, COMMIT, komunikat, runs |
| `tools/mcp-server.mjs` | nowy — serwer MCP (2 narzędzia odczytu) |
| `tools/test-mcp-server.mjs` | nowy — 4 testy |
| `docs/mcp.md` | nowy — możliwości istniejącego serwera i tych narzędzi |
| `docs/README.md` | zmieniony — indeks i lista wyjątków |
| `.gitignore` | zmieniony — `!docs/mcp.md` |
| `.github/workflows/pr-checks.yml` | zmieniony — `mcp:deployments:test` |
| `package.json` | zmieniony — dwa skrypty npm |
| `tools/test-{simulate-vault,preflight-plan,verify-vault,configure-strategy,execute-plan,execution-journal,export-safe-plan}.mjs` | zmienione — wykrywanie providera honoruje `FUSION_ENV_FILE` |

## Pliki w `git status`, które NIE należą do tego commita

- zmiany T25–T51. `.gitignore`, `docs/README.md`,
  `.github/workflows/pr-checks.yml` i `package.json` są wspólne z wcześniejszymi
  zadaniami serii.

## Komendy dla hosta

```bash
cd ~/repos/ipor-fusion
git add agent-readiness/PLAN.md agent-readiness/STATUS.md agent-readiness/tasks/T52/
git add tools/mcp-server.mjs tools/test-mcp-server.mjs docs/mcp.md docs/README.md .gitignore
git add .github/workflows/pr-checks.yml package.json
git add tools/test-simulate-vault.mjs tools/test-preflight-plan.mjs tools/test-verify-vault.mjs
git add tools/test-configure-strategy.mjs tools/test-execute-plan.mjs tools/test-execution-journal.mjs tools/test-export-safe-plan.mjs
git status --short
git commit -F agent-readiness/tasks/T52/commit-message.txt
```

Po commicie: w `agent-readiness/STATUS.md` zmień wiersz T52 na `committed <hash>`.

# Środowisko wykonania — fakty zweryfikowane

Aktualizuj ten plik, gdy coś się zmieni. Data ostatniej weryfikacji: **2026-09-07**.

## Git

- Repo: `/Users/piotrrzonsowski/repos/ipor-fusion` (w VM też jako `/home/ipor/repos/ipor-fusion`).
- Branch roboczy: `feature/agents-support`. Plan pisany na `6e1fd02`, HEAD przy starcie `a1f79d6`
  (6e1fd02 jest przodkiem — plan pozostaje aktualny).
- **W VM katalog `.git` jest zamontowany read-only** (9p, host-enforced). `git status`, `git log`,
  `git diff` działają; `git add/commit/stash/checkout` nie. Commity robi Pete ręcznie na hoście
  na podstawie `tasks/Txx/COMMIT.md`.
- Brak poświadczeń GitHub w VM. `gh` nie działa.

## Toolchain

| Narzędzie | Lokalnie (VM) | CI |
| --- | --- | --- |
| Foundry | forge 1.7.1 (2026-05-08) | `foundry-toolchain` v1.9.1, `version: stable` (niezapinane) |
| Node | v24.16.0 | 20.17.0 |
| npm | 11.13.0 | z Node 20 |
| Solidity | 0.8.30 (foundry.toml) | jw. |
| Prettier | 3.8.1 + prettier-plugin-solidity 2.2.1 (package.json) | jw.; pre-commit ma 3.2.5 + 1.3.1 |

`node_modules/`, `lib/forge-std`, `lib/foundry-random`, `out/`, `cache/` są obecne — build jest
scache'owany.

## RPC

Zmienne czytane przez testy (`vm.envString`): `ETHEREUM_PROVIDER_URL` (127 testów),
`ARBITRUM_PROVIDER_URL` (47), `BASE_PROVIDER_URL` (24), `TAC_PROVIDER_URL` (2), `INK_PROVIDER_URL` (2).

Stan `.env` (tylko nazwy, wartości nigdy nie kopiować):

| Zmienna | Stan | chain-id |
| --- | --- | --- |
| ETHEREUM_PROVIDER_URL | ustawiona, odpowiada | 1 |
| ARBITRUM_PROVIDER_URL | ustawiona, odpowiada | 42161 |
| BASE_PROVIDER_URL | ustawiona, odpowiada | 8453 |
| INK_PROVIDER_URL | ustawiona, odpowiada | 57073 |
| TAC_PROVIDER_URL | **pusta** | — |

`.env` zawiera też `ETHERSCAN_API_KEY`, `LOCAL_RPC_URL`, `UNI_PROVIDER_URL`,
`FOUNDRY_DISABLE_NIGHTLY_WARNING`, których testy nie używają. Załadowanie do shella:
`set -a; . ./.env; set +a`.

## Repo — stan wyjściowy istotny dla zadań

- `.gitignore` ignoruje `docs/`, `CLAUDE.md`, `.claude/`, `GEMINI.md`, `ai_context`, `reports/`,
  `research/`, `temp/`, `TODO.MD`. `agent-readiness/` **nie** jest ignorowany.
- Lokalnie istnieje prywatny `docs/superpowers/` — ma pozostać ignorowany (T01).
- Brak: `.env.example`, `tools/check_coverage.sh`, `AGENTS.md`, `CLAUDE.md`, `script/`,
  `deployments/`, `abi/`, `catalog/`, `config/`, `evals/`.
- `package.json` scripts: `solhint:*`, `prettier:*` (wszystkie `--write`), `coverage:file`
  (martwy). Brak `test:*`, `format:check`, `agent:*`.
- `foundry.toml`: `[profile.default]` (cancun, ffi=true, fs read-write `./`, isolate=false) i
  `[profile.arbitrum]` (paris). **Brak `[profile.ci]`** mimo `FOUNDRY_PROFILE=ci` w CI.
- CI: `ci.yml` używa `pull_request_target` + job `authorize` z environments `external`/`internal`;
  `smart-contracts-build.yml` robi `npm install`, `forge test -vvv` z sekretami RPC, `prettier:all`
  z `--write`.
- `test/unitTest/` ma 2 pliki, żaden nie czyta RPC. Reszta testów w większości forkowa.

## Narzędzia zewnętrzne

- MCP `ipor-fusion-mcp-vpn` (`fusion_address_lookup`, `fusion_address_names`, `contract_abi`, …)
  jest skonfigurowane, ale każde wywołanie wymaga zgody Pete'a w sesji. Zadania T20+ z niego
  korzystają — uprzedzić przed użyciem.
- Rejestr `ipor-abi` — sprawdzić przed stwierdzeniem, że coś nie jest wdrożone.
- Skrypt Jira: `bash ~/.claude/knowledge/bin/jira.sh` (nieużywany przez ten plan).

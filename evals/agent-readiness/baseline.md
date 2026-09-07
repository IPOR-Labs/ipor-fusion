# Agent-readiness baseline

Measurement record for the eight tasks defined in [`tasks.json`](tasks.json)
(source: `agent-readiness/PLAN.md`, section 10). Every later run repeats the same
tasks under the same conditions and is appended here as a new run section, so that
"the repository got easier to work in" is a measured claim and not an impression.

There is no automated runner. A human operator starts one fresh agent session per
task, scores it against the task's `pass_criteria`, and fills in the tables below.

## How a run is made

1. Check out the commit named in the run's conditions with a clean working tree.
2. Start **one session per task**, with **no private memory loaded** — the suite
   measures this repository, not the operator's knowledge base. Use `claude --bare`
   (it skips auto-memory and `CLAUDE.md` auto-discovery), or start the session under
   a `HOME` that contains neither `~/.claude/knowledge` nor a global `CLAUDE.md`.
   A session that did load private memory is recorded as a separate run and is
   **never** labelled a pre-configuration baseline.
3. Give the agent the task `prompt` verbatim, plus the fixture values pinned below.
   Nothing else.
4. Score `pass` / `fail` / `blocked` against `pass_criteria`, and record the six
   metrics from `tasks.json`. `blocked` means the agent correctly reported a missing
   prerequisite instead of guessing; it is a valid report of a limitation and not a pass.
5. Repeat the suite three times (`repeats_per_run`) before drawing a conclusion.

## Fixtures

Pinned once during run 1 and then reused verbatim, so runs stay comparable.

| Fixture | Value | Pinned in |
| --- | --- | --- |
| `pilot_network` | not pinned yet | — |
| `pilot_factory_address` | not pinned yet | — |
| `injected_fuse_bug` | not pinned yet | — |
| `mismatch_case` | not pinned yet | — |
| `upgrade_vs_usage_test_pair` | not pinned yet | — |

E1, E3 and E8 need no network fixture; E1 is anchored on the existing
`PlasmaVault.UnsupportedFuse()` revert and E8 on a pair of tests under `test/factory/`
that the operator selects once and then keeps.

## Run 1 — baseline (not executed yet)

### Conditions

Verified on the machine that will host the run, on 2026-09-07.

| Field | Value |
| --- | --- |
| Commit | `a81cd22` (`docs(agents): split readiness plan into atomic tasks`), branch `feature/agents-support` |
| Model | to be recorded per session at run time |
| Client | Claude Code CLI, `claude --bare` (memory-free mode) |
| Tools available | Bash, file read/write, Foundry; no GitHub credentials; MCP `ipor-fusion-mcp-vpn` reachable only over the operator's VPN and only with per-call approval |
| Work budget | to be fixed before run 1 and then held constant across repeats |
| Memory mode | none (required) |
| Toolchain | forge 1.7.1, Node v24.16.0, npm 11.13.0, solc 0.8.30 |
| Network access | `ETHEREUM_PROVIDER_URL`, `ARBITRUM_PROVIDER_URL`, `BASE_PROVIDER_URL`, `INK_PROVIDER_URL` respond; `TAC_PROVIDER_URL` is empty |

Only variable **names** are ever written here; values stay in `.env`.

### Results

| Task | Score | Time to first relevant test | Human interventions | Tokens | Redundant reads | Evidence quality | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| E1 | not run | | | | | | |
| E2 | not run | | | | | | |
| E3 | not run | | | | | | |
| E4 | not run | | | | | | |
| E5 | not run | | | | | | |
| E6 | not run | | | | | | |
| E7 | not run | | | | | | |
| E8 | not run | | | | | | |

Success rate: not measured. Targets for comparison: ≥ 80 % pass across three
independent repeats, every executable recipe green in CI, and zero uses of an
invented address or an unconfirmed ABI.

### Access gaps that already constrain run 1

Established while preparing this file, on 2026-09-07:

- **The run cannot be started from inside a session that has private memory loaded.**
  The measurement has to be launched by the operator from a memory-free session.
- **`claude --bare` needs `ANTHROPIC_API_KEY` or an `apiKeyHelper`** (OAuth and the
  keychain are not read in that mode). Neither `ANTHROPIC_API_KEY` nor
  `CLAUDE_CODE_OAUTH_TOKEN` is set in this environment, so the operator supplies the
  credential or uses the scratch-`HOME` variant instead.
- **`TAC_PROVIDER_URL` is empty**, so no task may pin TAC as `pilot_network` until it
  is filled; the fork tasks (E5, E6) would be `blocked` there.
- **No GitHub credentials in this environment**, so nothing in the suite may depend on
  `gh` or on CI state.
- **The MCP deployment lookup requires per-call approval** and a VPN connection, which
  makes E4 sensitive to operator availability — record every approval as a human
  intervention.

### Starting state of the repository at this commit

Recorded so that a later run can attribute changes in the scores to the work in
between: no `AGENTS.md`, no `.env.example`, no `docs/README.md`, no `deployments/`,
`abi/` or `catalog/` directory, no `test:*` or `agent:*` npm scripts, no `format:check`,
and no `[profile.ci]` in `foundry.toml` even though CI sets `FOUNDRY_PROFILE=ci`.

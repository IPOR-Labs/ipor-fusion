# Continuous integration

Two kinds of check run against a pull request, and the split between them is a
security boundary, not a convenience.

| Workflow                                                | Trigger                | Runs the PR's code | Has secrets |
| ------------------------------------------------------- | ---------------------- | ------------------ | ----------- |
| [`pr-checks.yml`](../.github/workflows/pr-checks.yml)   | `pull_request`         | **yes**            | **no**      |
| [`ci.yml`](../.github/workflows/ci.yml)                 | `pull_request_target`  | yes, via the build workflow | yes (RPC providers, Slack) |

## The secret-free job

`pr-checks.yml` is what a contributor — human or agent — should expect to pass
before review. It declares `permissions: contents: read`, passes no `secrets:`
to anything, and every step works offline:

- `forge build` and `npm run solhint:all`;
- `npm run format:check`, which gates: every `.sol` file under `contracts/` and
  `test/` must already be in Prettier style;
- `npm run test:unit` — the local contract suites, no RPC, no FFI;
- schema and registry validation: test suites, deployment manifests, the pilot
  ABI, the vault configuration example, the integration catalog, and
  `catalog:check` for generated metadata;
- `npm run validate:docs`, which resolves every relative link and heading anchor
  in the shipped documentation without fetching anything;
- the tooling tests that do not need a provider, run with
  `FUSION_ENV_FILE=/dev/null` so that a missing provider fails by name instead of
  passing quietly.

Because it is triggered by `pull_request`, a fork's run receives a read-only
token and no repository secrets. Running the pull request's code there is
therefore safe.

### What the documentation check covers

`validate:docs` reads the files this repository ships — `docs/`, the root
`README.md`, every `AGENTS.md` and `evals/` — taken from what git tracks or would
track. Private notes ignored under `docs/` are out of scope by construction, and
`agent-readiness/tasks/` is excluded because those per-task logs quote paths as
prose.

It resolves every relative link and, for links into Markdown files, checks that
the `#anchor` is a real heading there. External links are counted and never
fetched, so the job stays offline and cannot fail because someone else's site is
down. Links inside fenced code blocks are examples, not references.

Together with `validate:deployments` (manifest paths and ABI hashes) and
`catalog:check` (generated metadata still matching the sources), a broken link, a
missing ABI and a stale generated artifact each fail the job.

### Formatting

`npm run format:check` gates. The pre-existing baseline (303 `.sol` files that
were not in Prettier style when the job was added) was closed by one
formatting-only commit, verified by building the tree before and after it with
CBOR metadata disabled and comparing every creation and runtime bytecode: they
were identical. Since then the check is expected to be clean on `main`.

If the check fails on your pull request, run `npm run prettier:all` (or the
pre-commit hook, which uses the same Prettier and plugin versions) and commit the
result together with your change. Keep formatting of files outside your scope in
a separate commit so that the review diff stays readable.

`solhint` reports warnings, not errors, and gates as well.

## The privileged workflow

`ci.yml` is triggered by `pull_request_target`, which means it runs in the
context of the base repository **with** access to secrets, and its build workflow
checks out `refs/pull/<n>/merge` — the pull request's code. GitHub documents the
risk of that combination in
[Securely using `pull_request_target`](https://docs.github.com/en/actions/reference/security/securely-using-pull_request_target).

Two things stand between a fork's code and those secrets today:

1. the `authorize` job, which selects the `external` environment for a pull
   request from a fork and `internal` otherwise;
2. whatever protection rules those GitHub environments actually carry.

**The second one cannot be verified from this repository.** Environment
protection rules, required reviewers and secret scoping live in the repository's
GitHub settings. Whoever administers the repository should confirm that the
`external` environment requires a review before any job that receives secrets
runs. Until that is confirmed, treat `ci.yml` as privileged and keep every check
that a contributor is expected to iterate on in `pr-checks.yml` instead.

Notifications (Slack) need a token and therefore stay in the privileged workflow.
They are separate jobs from anything that executes pull request code.

## The trusted fork job

[`pilot-fork-checks.yml`](../.github/workflows/pilot-fork-checks.yml) runs what
needs an archive provider. It is `workflow_call` only — it cannot be triggered
directly — and `ci.yml` calls it behind the same `authorize` gate as the build,
passing exactly one secret: `ETHEREUM_PROVIDER_URL`.

Its steps, in order:

1. **`agent:doctor --rpc --chain 1 --block <pinned>`** first, so that a provider
   problem is reported as infrastructure and never mistaken for a contract
   failure. The doctor separates `RPC_UNAVAILABLE`, `CHAIN_MISMATCH` and
   `HISTORICAL_STATE_UNAVAILABLE`, and a failure here emits a CI error that says
   so and points at [`troubleshooting.md`](troubleshooting.md).
2. **The `deployed-factory` suites** on the pinned block — the compatibility test
   and the strategy lifecycle against the unchanged deployment.
3. **A manifest check**: `factory:inspect` at the same block, compared with
   `deployments/1/factories.json`. A different implementation or reported version
   fails the job; it never rewrites the manifest.
4. **The inspection report is uploaded as an artifact**, so a failure can be read
   after the fact.

No provider URL is ever printed: every tool reports the variable's name.

The block is an input with a default, so the job stays deterministic. Watching
for *changes* on a fresh block is a different job, on a schedule.

## The scheduled drift job

[`pilot-drift.yml`](../.github/workflows/pilot-drift.yml) runs
`npm run deployments:drift` once a day (and on manual dispatch) against a
**finalized** block, comparing the verified pilot deployment with the confirmed
state recorded in its verification report: the implementation behind the proxy,
the proxy's and the implementation's runtime code hashes, the reported factory
version, and every component the report named — both that the factory still uses
it and that its code hash is unchanged.

Three outcomes, deliberately distinct:

| Exit | Job result | Meaning                                                                 |
| ---- | ---------- | ------------------------------------------------------------------------ |
| `0`  | success    | Unchanged.                                                               |
| `1`  | failure    | **Drift**: something the report recorded is now different.               |
| `2`  | failure    | The comparison could not be made — provider, block or a missing artifact. |

The two failures emit different CI errors, because "the factory was upgraded" and
"the RPC did not answer" call for different actions. The report is uploaded as an
artifact either way.

Drift is a signal for a person: the job never rewrites the manifest, never
promotes a new implementation to `verified`, and never re-pins the historical
blocks that fixtures and regression tests use. Re-verification is the T26
procedure, run again by hand.

## What is not covered here

- **`agent:doctor` without `--rpc`** is offline but is not run in CI, because it
  inspects the local machine rather than the repository.
- **Other networks and other deployments** — the drift job checks the one
  `verified` entry that exists.
- **GitHub environment protection rules** — see above; they must be confirmed in
  the repository's settings by an administrator. This repository changes no
  organisation or repository permissions.

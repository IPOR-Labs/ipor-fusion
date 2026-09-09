# Test contributor instructions

These instructions supplement the repository root `AGENTS.md` for `test/`.

## Start here

- Read [`../docs/testing.md`](../docs/testing.md) for how to choose a suite, what
  a fixture proves, and how to tell an infrastructure failure from a regression.
- Read [`../config/test-suites.json`](../config/test-suites.json) before quoting
  a result from a classified suite. It records the provider variable, pinned
  block, profile, FFI use, fixture type and `setUp()` mutations of each one.
- Only the factory pilot suites are classified so far. An unlisted suite carries
  no claim in either direction — read its `setUp()` yourself.

## Layout

`test/` mirrors `contracts/` for the most part, with shared fixtures and
builders under `test/test_helpers/`. Two conventions are worth knowing before
you go looking:

- A directory named `unitTest` does not mean the suite is local. Check
  `vm.createSelectFork` and `vm.envString` in the file itself.
- Directory names do not always match `contracts/`. Search by contract name
  rather than assuming the path.

## Classify before you quote a result

Every suite belongs to exactly one of four fixture types. The type decides what
a pass is evidence for, and it is the single most common thing to get wrong.

| Fixture                 | What it builds                                                                                  | What a pass proves                               |
| ----------------------- | ----------------------------------------------------------------------------------------------- | ------------------------------------------------ |
| `local-deployment`      | Everything, from source, with no chain state.                                                   | The checked-out code behaves as written.         |
| `fork-fresh-deployment` | Fork state, but the contract under test is deployed by the fixture.                             | The checked-out code works among real protocols. |
| `fork-upgrade`          | An existing proxy on a fork, deliberately upgraded or reconfigured.                             | The new version would work if it were deployed.  |
| `deployed-usage`        | An existing deployment used unchanged — no upgrade, no code replacement, no self-granted roles. | That the live deployment is usable as it stands. |

Only `deployed-usage` says anything about a live deployment. **No suite in this
repository currently has that type.** In particular, both fork suites under
`test/factory/` deploy their own `FusionFactory`, their own bases and their own
component factories, reading the mainnet proxy only to copy configuration. They
are `fork-fresh-deployment`, and a pass is not evidence that the deployed
factory can create a vault.

If you add or reclassify a suite, add its entry to `config/test-suites.json` in
the same change and record the run that produced the numbers.

## Running tests

```bash
forge build
npm run test:unit
npm run validate:test-suites
```

Use the exact `profile` named by the catalog. The two factory pilot profiles
deny FFI and filesystem access because the classified suites need neither.
Do not silently fall back to `default`: that would make the test pass with more
capabilities than its catalog entry promises.

`npm run test:unit` is the canonical credential-free entry point for the
classified local subset. It does not mean every unit-looking directory in the
repository is included; read its exact coverage in `docs/testing.md`.

Suites with `"rpc": null` in the catalog need no credentials. Suites with a
provider variable need your own archive-capable endpoint; Foundry reads the
ignored `.env` in the repository root by itself, and an already-exported
variable takes precedence over it. Never write a URL into a test, a catalog
entry, a log or a report — variable names only.

Keep pinned fork blocks as they are unless the task explicitly validates and
records a new one. Changing a block silently changes what the test measures.

## Writing tests

- Start with the smallest suite next to the changed module, then widen to the
  affected trust boundary. `docs/testing.md` has the per-area rules.
- A regression test must reach the defective path and fail for the intended
  reason when the fix is reverted. Prove that, do not assume it.
- Do not make a test pass by replacing deployed code, upgrading a component or
  granting yourself a role, unless that setup is the behavior under test. When a
  fixture does this deliberately, say so in the test name and in the handoff.
- Keep signer, direct caller, vault owner, AccessManager and strategy operator
  as distinct addresses whenever production behavior distinguishes them. The
  direct caller selects the fee package; collapsing identities hides that.
- State units and rounding at assertion boundaries. Use justified tolerances
  rather than assuming exact ERC-4626 conversion equality.
- `foundry.toml` sets `isolate = false` on purpose: fuse tests write transient
  storage in one call and read it in another. Do not turn it on to fix a test.

Do not change compiler settings and do not enable `via_ir`. Do not add indexed
event parameters when writing test events; this repository keeps event
parameters in the data section.

## Reporting a run

Give the command, the pass/fail counts, the fixture type, and — for a fork run —
the network and pinned block. Report a missing provider or missing archive state
as an infrastructure limitation, never as a passing or failing protocol result.
Failures you inherited from the base commit are stated separately from failures
your change caused.

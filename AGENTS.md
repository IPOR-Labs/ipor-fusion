# Repository instructions

These are the canonical repository instructions for human contributors and coding agents. They apply to the entire
checkout. A more specific `AGENTS.md`, when present below a directory, supplements these instructions for that subtree.

## Project and sources of truth

IPOR Fusion is a Solidity framework for modular, upgradeable ERC-4626 vaults. Changes can affect accounting, access
control, and assets managed on-chain, so prefer evidence from code and tests over assumptions.

- Start with [README.md](README.md) for installation and [docs/README.md](docs/README.md) for the documentation index.
- Use [docs/architecture.md](docs/architecture.md) for the current vault map; the more detailed
  [contracts/vaults/README.md](contracts/vaults/README.md) is supplementary and may describe historical components.
- Treat source code, tests, and tracked artifacts as repository truth. Private notes or agent memory are not required.
- No deployment registry, versioned ABI directory, vault config, or factory recipe is tracked yet. Their rollout is
  planned in [agent-readiness/PLAN.md](agent-readiness/PLAN.md); do not invent missing addresses, ABIs, or status.
- Absence from this checkout does not prove that a contract is not deployed. Use a maintained registry or an on-chain
  read, and record its source, network, and block when deployment identity matters.

## Repository map

- `contracts/vaults/`: PlasmaVault entry points, bases, initializers, plugins, and vault storage libraries.
- `contracts/factory/`: vault, wrapper, and price-feed factories. Also inspect
  `contracts/managers/fee/FeeManagerFactory.sol` for complete vault factory flows.
- `contracts/fuses/`: protocol actions and balance fuses executed in the vault context.
- `contracts/rewards_fuses/`: reward-specific integrations.
- `contracts/managers/`: access, context, fee, price, rewards, and withdrawal management.
- `contracts/price_oracle/`: middleware and price-feed implementations.
- `contracts/deploy/initialization/`: initialization structs and helper types; this is not a deployment registry.
- `contracts/libraries/` and `contracts/interfaces/`: shared storage, math, errors, markets, and public interfaces.
- `test/`: tests organized mostly like `contracts/`; shared fixtures and builders are under `test/test_helpers/`.
- `docs/`: selectively tracked, team-facing documentation. Follow its index when adding a document.
- `agent-readiness/`: implementation plan and task evidence, not product or deployment documentation.

On first search, exclude `node_modules/`, `lib/`, `out/`, and `cache/` unless the task concerns dependencies or generated
artifacts. Prefer `rg` and `rg --files` for repository discovery.

## Setup and verified commands

Use the versions and setup documented in [README.md](README.md):

```bash
git submodule update --init --recursive
npm ci
foundryup --install v1.7.1
forge --version
forge build
```

Run a local factory suite that does not require RPC credentials:

```bash
npm run test:unit
```

Fork tests read provider names from the ignored `.env` file. Copy [.env.example](.env.example), supply only your own RPC
URLs, and use archive-capable endpoints for pinned historical blocks. For example:

```bash
forge test --match-path test/factory/FusionFactoryDaoFeePackagesForkTest.t.sol -vvv
```

Do not interpret a missing provider or unavailable archive state as a passing or failing protocol regression. Report it
as an infrastructure limitation. Inspect `setUp()`, helpers, `vm.envString`, and `vm.createSelectFork`; a directory named
`unitTest` does not by itself prove that a test is local.

Check formatting without writing, format deliberately, and lint as separate operations:

```bash
npm run format:check
npm run prettier:all
npm run solhint:all
```

If `format:check` reports pre-existing drift, do not run the writing command across the repository merely to make an
unrelated change pass; format only files in scope and report inherited failures.

## Choosing and writing tests

- Start with the smallest test file next to the changed module, then expand according to the affected trust boundary.
- A fuse change normally requires its matching `test/fuses/<integration>/` or `test/unitTest/fuses/<integration>/` tests.
- Vault storage, accounting, access, oracle, or common library changes require the direct suite plus affected callers.
- Factory changes start with `test/factory/`; identify whether the test uses a fresh factory or an existing deployment.
- Preserve pinned fork blocks unless the task explicitly validates and records a new block.
- A regression test must reach the defective path and fail for the intended reason when the fix is reverted.
- Do not make tests pass by replacing deployed code, upgrading components, or granting roles unless that setup is the
  behavior under test. State such mutations when a fork test intentionally uses them.
- Documentation-only changes require link, command, formatting, and diff checks; contract suites are not automatically
  necessary.

## Solidity and protocol rules

- Fuses, bases, and plugins may run through `delegatecall`: storage writes affect the PlasmaVault, while `msg.sender` and
  execution context follow delegatecall semantics. Confirm the actual call chain before changing authorization or state.
- Use the existing ERC-7201 namespaced storage libraries. Never reuse a namespace or reorder upgradeable storage without
  a compatibility analysis and a storage-layout test where relevant.
- Protect initialization and reinitialization, validate required nonzero dependencies, and prevent a second setup path.
- Identify signer, direct caller, vault owner, AccessManager, and strategy operator separately. Tests must not collapse
  those identities when production behavior depends on them.
- State units at boundaries: token smallest units and decimals, WAD-style values, BPS, and seconds. Document rounding
  direction and use justified tolerances instead of assuming exact ERC-4626 conversion equality.
- Preserve external ABI, selectors, errors, event layout, and storage compatibility unless the task explicitly changes
  them and covers migration impact. Event parameters in this project are deliberately not `indexed`; do not add it.
- `via_ir = true` is forbidden. Do not change Solidity, EVM, optimizer, or other `foundry.toml` compiler settings without
  explicit maintainer sign-off and task-specific validation.
- Keep market IDs, substrate encoding, price dependencies, approvals, and balance-fuse accounting consistent across an
  integration. Inspect both enter/exit behavior and valuation paths.

## Evidence and deployment safety

Keep these claims distinct:

- A local test proves behavior of the checked-out source under that test setup.
- A fork test proves behavior at its selected chain and block, including every cheatcode mutation made by the fixture.
- A future tracked deployment manifest will identify a reviewed deployment and its matching ABI; it will not prove live
  state forever.
- An on-chain read proves the observed state only for the named network, address, and block.

If these disagree, stop and explain the discrepancy. Do not silently substitute a fresh deployment, current ABI, proxy
implementation, caller, fee package, or block. Before operational work, re-check proxy implementation, component code,
roles, and configuration with the ABI that belongs to that deployed version.

Never broadcast, sign, upgrade, grant roles, or change public-chain state unless the user has explicitly placed that
operation and its scope in the task. Simulation is not authorization to execute.

## Change hygiene and handoff

- Inspect `git status` before editing. Preserve user changes and keep unrelated formatting or generated files out.
- Never commit `.env`, RPC URLs, keys, mnemonics, signer material, or copied production calldata containing secrets.
- Keep changes atomic. Do not use destructive Git commands to clean a shared worktree.
- For a bug fix: reproduce, identify the cause, add a focused regression test, implement, run narrow tests, then expand
  based on risk.
- In the handoff, list changed files, commands run, pass/fail counts, inherited failures, fork network/block if used, and
  anything not verified.
- A green test is evidence, not a substitute for describing the caller, state assumptions, and path it exercised.

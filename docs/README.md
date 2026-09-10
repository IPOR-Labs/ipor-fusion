# Documentation index

This directory holds the curated, team-facing documentation of this repository:
documents that a new contributor — or an AI agent working from a plain checkout —
is expected to find and trust. It is not a scratch space. Personal notes, drafts,
plans and exported conversations stay out of version control.

## What is tracked here

`.gitignore` ignores everything under `docs/` and then re-includes tracked files
one by one:

```gitignore
docs/*
!docs/README.md
!docs/architecture.md
!docs/roles-and-permissions.md
!docs/factories.md
!docs/testing.md
!docs/deployments.md
!docs/vaults.md
!docs/fuse-catalog.md
!docs/invariants.md
!docs/troubleshooting.md
!docs/ci.md
!docs/release.md
!docs/mcp.md
!docs/recipes/
!docs/recipes/*.md
```

Only the curated files listed in this index are tracked. Every further document
is added together with its own exception line, in the same commit as the document,
so that adding a file to `docs/` never publishes anything by accident. Local
material — for example a private `docs/<my-notes>/` directory — remains ignored
without any extra step.

Verify the rule at any time:

```bash
git check-ignore -q docs/README.md   # exit 1: not ignored, the index is tracked
git check-ignore -q docs/scratch.md  # exit 0: matched docs/*, local files stay private
```

## How to add a document

1. Write the document in English, as Markdown, with a lowercase, hyphenated
   filename (`architecture.md`, `roles-and-permissions.md`).
2. Add `!docs/<file>.md` under the documentation section of `.gitignore`. For a
   whole directory, un-ignore the directory and its contents
   (`!docs/recipes/`, `!docs/recipes/*.md`).
3. Link it from the index below, and link from it to the code it describes using
   relative paths, so that every claim can be checked against the source.

Rules that apply to anything committed here: no secrets — no RPC URLs, API keys
or `.env` contents, variable **names** only; no invented addresses, ABIs, block
numbers or versions; and a statement about a deployment names the network and the
source it was read from.

## Documentation that already exists in the repository

Documentation currently lives next to the code it describes. Until a document in
this directory replaces one of these, the source below is the reference.

| Topic                                                                | Where                                                                                                                                                                                                                                  |
| -------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Project overview, installation, build, tests, pre-commit hooks       | [`../README.md`](../README.md)                                                                                                                                                                                                         |
| Current vault architecture, routing, storage, managers, call traces  | [`architecture.md`](architecture.md)                                                                                                                                                                                                   |
| Factory and vault roles, callers, administrators and delays          | [`roles-and-permissions.md`](roles-and-permissions.md)                                                                                                                                                                                 |
| Factory selection, composition, versions and test modes              | [`factories.md`](factories.md)                                                                                                                                                                                                         |
| Deployment sources, evidence levels and selected factory pilot       | [`deployments.md`](deployments.md)                                                                                                                                                                                                     |
| Test suite selection, fixture types, providers, blocks and failures  | [`testing.md`](testing.md)                                                                                                                                                                                                             |
| Vault creation input, units, caller/owner roles and variants         | [`vaults.md`](vaults.md)                                                                                                                                                                                                               |
| End-to-end recipe: create a vault through the deployed factory       | [`recipes/create-vault.md`](recipes/create-vault.md)                                                                                                                                                                                   |
| End-to-end recipe: run the ERC4626 pilot strategy                    | [`recipes/erc4626-strategy.md`](recipes/erc4626-strategy.md)                                                                                                                                                                           |
| Recipe: wrap a pilot vault with the deployed wrapper factory         | [`recipes/wrap-a-vault.md`](recipes/wrap-a-vault.md)                                                                                                                                                                                   |
| Integration catalog: markets, substrates, valuation, roles, evidence | [`fuse-catalog.md`](fuse-catalog.md)                                                                                                                                                                                                   |
| Pilot invariants and whether a test proves each of them              | [`invariants.md`](invariants.md)                                                                                                                                                                                                       |
| Symptom-to-cause troubleshooting for the factory and vault path      | [`troubleshooting.md`](troubleshooting.md)                                                                                                                                                                                             |
| CI: the secret-free pull request job and the privileged workflow     | [`ci.md`](ci.md)                                                                                                                                                                                                                       |
| Release checklist for the deployment registry and its evidence       | [`release.md`](release.md)                                                                                                                                                                                                             |
| Reading the deployment registry through MCP                          | [`mcp.md`](mcp.md)                                                                                                                                                                                                                     |
| Detailed vault component background and historical design notes      | [`../contracts/vaults/README.md`](../contracts/vaults/README.md)                                                                                                                                                                       |
| Per-integration fuse notes (substrates, markets, enter/exit data)    | one `README.md` per integration under [`../contracts/fuses/`](../contracts/fuses/)                                                                                                                                                     |
| Reward fuse notes                                                    | [`euler`](../contracts/rewards_fuses/euler/README.md), [`merkl`](../contracts/rewards_fuses/merkl/README.md), [`syrup`](../contracts/rewards_fuses/syrup/README.md) under [`../contracts/rewards_fuses/`](../contracts/rewards_fuses/) |

List the integration documents that exist in the current checkout:

```bash
git ls-files 'contracts/**/README.md'
```

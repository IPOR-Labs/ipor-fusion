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
```

Only this index is tracked today. Every further document is added together with
its own exception line, in the same commit as the document, so that adding a file
to `docs/` never publishes anything by accident. Local material — for example a
private `docs/<my-notes>/` directory — remains ignored without any extra step.

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

| Topic                                                                | Where                                                                                      |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| Project overview, installation, build, tests, pre-commit hooks       | [`../README.md`](../README.md)                                                             |
| Vault architecture: PlasmaVault, base, plugins, governance, managers | [`../contracts/vaults/README.md`](../contracts/vaults/README.md)                           |
| Per-integration fuse notes (substrates, markets, enter/exit data)    | one `README.md` per integration under [`../contracts/fuses/`](../contracts/fuses/)         |
| Reward fuse notes                                                    | [`../contracts/rewards_fuses/euler/README.md`](../contracts/rewards_fuses/euler/README.md) |

List the integration documents that exist in the current checkout:

```bash
git ls-files 'contracts/**/README.md'
```

## Related, but not documentation

- [`../agent-readiness/`](../agent-readiness/) — the plan and task log for making
  this repository workable by AI agents. Process files, written in Polish.
- [`../evals/agent-readiness/`](../evals/agent-readiness/) — the measurement suite
  that checks whether that work had an effect.

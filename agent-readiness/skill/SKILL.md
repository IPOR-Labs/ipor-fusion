---
name: readiness-task
description: Execute exactly one task (Txx) from agent-readiness/PLAN.md — verify dependencies, implement the scope, run the acceptance checks, write LOG.md + COMMIT.md under agent-readiness/tasks/Txx/, update STATUS.md, then stop. Use when the user says "zrób T05", "readiness task T12", "/readiness-task T20" or asks to continue the AI-agent-readiness plan.
---

# Readiness task — one task, one documented result, one prepared commit

## Contract

- **Input:** a task ID `Txx` (argument, or ask if missing). Nothing else.
- **Output:** the task's scope implemented in the working tree, plus three files:
  `agent-readiness/tasks/Txx/LOG.md`, `agent-readiness/tasks/Txx/COMMIT.md`, and an updated
  `agent-readiness/STATUS.md`. The plan checkbox for `Txx` is flipped to `[x]` in `PLAN.md`.
- **You never run `git commit`, `git add`, `git push`, `git stash` or `git checkout -- <file>`.**
  Pete commits manually after reviewing COMMIT.md. In the VM `.git` is read-only anyway.
- **You never continue to the next task.** Finish `Txx`, report, stop.

## Where things live

```
agent-readiness/
├── PLAN.md          # sections 1–8 = target design, section 9 = task list (Txx), section 10 = evals
├── STATUS.md        # one row per task: status, date, commit hash once Pete committed
├── ENVIRONMENT.md   # verified facts about this machine (RPC, versions, read-only .git, …)
├── README.md        # how the workflow works (for humans)
├── skill/           # this skill (symlinked from .claude/skills/readiness-task)
│   └── templates/   # LOG.md and COMMIT.md templates — copy them, do not invent a format
└── tasks/Txx/       # LOG.md + COMMIT.md per task, plus any evidence files (test output, reports)
```

Paths inside PLAN.md are relative to `agent-readiness/`, so `../README.md` means the repo README.

## Workflow

### 0. Reconcile state before touching anything

1. `git status --short` — note pre-existing changes. They belong to someone else: never revert,
   format, or include them in COMMIT.md.
2. `git log --oneline --all | grep -E "\bT[0-9]{2}\b"` — every task ID found in a commit message
   is **committed**. If STATUS.md says `ready-for-commit` for such a task, update it to
   `committed <hash>`. If STATUS.md says `committed` but the working tree still has that task's
   files uncommitted, stop and tell the user: the state is inconsistent.
3. If `agent-readiness/tasks/Txx/` already exists, read LOG.md first — you may be resuming.

### 1. Read the task and gate on dependencies

1. Open PLAN.md and read the `#### Txx` block: priority, size, **Zależności**, **Zakres**,
   **Odbiór**, **Commit**. Read also section 9.1 (rules) once per session.
2. Read the relevant design section (1–8) that the task implements — the task block is a
   summary, the design section has the details and the pitfalls.
3. Every dependency must be `committed` or `ready-for-commit` in STATUS.md. If one is not:
   **stop**, report which dependency is missing, do not implement. Exception: the user explicitly
   says to proceed anyway — then record that in LOG.md under "Deviations".
4. Read ENVIRONMENT.md. If the task needs something the environment lacks (e.g. TAC RPC, GitHub
   settings, an MCP tool), decide now whether the task is doable, partially doable, or blocked.
   Blocked → write LOG.md with status `blocked` and the concrete missing item, update STATUS.md,
   stop.

### 2. Implement the scope — and only the scope

- Do exactly what **Zakres** says. If you notice adjacent problems, write them in LOG.md under
  "Follow-ups" — do not fix them.
- Read a file before editing it. Keep existing formatting; never run `prettier --write` over files
  you did not otherwise change.
- If the task turns out to be more than one independent result or more than a day, split it into
  `Txxa`, `Txxb` **in PLAN.md** (keeping dependencies) and implement only `Txxa`. Say so in the
  report.
- Documentation for the team goes in **English**; PLAN.md, LOG.md and COMMIT.md stay in
  **Polish** (they are Pete's process files).
- Every new npm script, doc link, or path you add must point at something that exists **after
  this task alone**. No forward references to future tasks.

### 3. Verify against "Odbiór"

- Turn each sentence of **Odbiór** into a concrete check and run it. Record the exact command
  and its trimmed output in LOG.md. "Should work" is not a result.
- Docs-only tasks: verify every link/path exists (`for p in …; do [ -e "$p" ] || echo BROKEN $p`)
  and every command you mention runs. Do not run the contract test suite for a docs change.
- Code/config tasks: run the narrowest relevant `forge build` / `forge test --match-path …` /
  `npm run …`. Fork tests need `set -a; . ./.env; set +a` first. A failure caused by a missing
  RPC is an **environment** result, not a pass — say which.
- A negative check (e.g. "a bad entry fails validation") must actually be executed with a bad
  input and its non-zero exit recorded.

### 4. Write the task files (templates are mandatory)

1. `cp agent-readiness/skill/templates/LOG.md agent-readiness/tasks/Txx/LOG.md` and fill every
   section. Steps are numbered, each with what was done, the command, and the result.
2. `cp agent-readiness/skill/templates/COMMIT.md agent-readiness/tasks/Txx/COMMIT.md` and fill it:
   - the commit subject from the plan's **Commit** line, verbatim;
   - a body of 2–6 lines: what changed and how it was verified;
   - the **exact file list** (`git status --short` filtered to this task's files, including
     `agent-readiness/tasks/Txx/*`, `agent-readiness/STATUS.md`, `agent-readiness/PLAN.md`);
   - the ready-to-paste commands for the host: one `git add` per file, then
     `git commit -F agent-readiness/tasks/Txx/commit-message.txt`.
3. Write `agent-readiness/tasks/Txx/commit-message.txt` with the subject, blank line, body.
4. Store evidence that is too long for LOG.md next to it (e.g. `forge-test.txt`), and link it.

### 5. Update STATUS.md and PLAN.md

- STATUS.md row for `Txx`: `ready-for-commit`, today's date (Europe/Warsaw), one-line note.
  If blocked: `blocked` + the missing item.
- PLAN.md: flip `- [ ]` to `- [x]` in the `Txx` block **only** when the acceptance checks passed.
  A blocked or partial task keeps `[ ]` and gets a `- **Blokada:** …` line under it.

### 6. Final report to the user (this is the only thing they reliably read)

Lead with the status word: **ready-for-commit**, **partial**, or **blocked**. Then:
- what was implemented (files, in words);
- which acceptance checks ran and their results, including anything that could not be verified;
- the path to COMMIT.md and the commit subject;
- deviations from the plan, if any.
Then stop. Do not suggest starting the next task unless asked.

## Hard rules (from the plan and from Pete)

- `via_ir = true` is forbidden. Never change `solc`, `evm_version`, `optimizer_runs` or add
  compiler profiles that alter them — that needs a separate agreement with Pete.
- Never use `indexed` on Solidity event parameters.
- Never write secrets: no RPC URLs with keys, no private keys, no `.env` contents in any file,
  log or report. Print variable **names** only. Do not modify `.env`.
- Never invent an address, ABI, block number or version. "Unknown" is a valid value; a guess is
  not. A manifest may be `candidate` without evidence; `verified` requires the report the plan
  demands.
- Never upgrade, replace or grant yourself roles on a deployed contract to make a test pass. Tests
  of an existing deployment use it unchanged.
- Never `git add .`, never include files you did not create for this task, never touch
  pre-existing uncommitted changes.
- Do not send transactions to a public network. Forks and Anvil only.

## Quick start for a fresh agent

```bash
cat agent-readiness/STATUS.md
sed -n '/^#### T05 /,/^#### T06 /p' agent-readiness/PLAN.md   # replace T05/T06 with your task and the next ID
cat agent-readiness/ENVIRONMENT.md
```

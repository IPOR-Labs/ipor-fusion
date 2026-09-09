#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { selectAffected } from "./lib/affected-tests.mjs";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const catalogPath = resolve(repoRoot, "config/test-suites.json");

function fail(code, message, exitCode = 1) {
    console.error(`test:affected: ${code}: ${message}`);
    process.exit(exitCode);
}

function parseArgs(argv) {
    let base;
    let dryRun = false;
    let json = false;
    for (let index = 0; index < argv.length; index += 1) {
        if (argv[index] === "--base" && argv[index + 1]) {
            base = argv[index + 1];
            index += 1;
        } else if (argv[index] === "--dry-run") {
            dryRun = true;
        } else if (argv[index] === "--json") {
            json = true;
            dryRun = true;
        } else {
            fail("INVALID_ARGUMENT", `unknown or incomplete argument ${JSON.stringify(argv[index])}`, 2);
        }
    }
    if (!base || base.startsWith("-") || !/^[A-Za-z0-9._/-]+$/.test(base)) {
        fail("INVALID_ARGUMENT", "--base must be a safe Git commit or reference", 2);
    }
    return { base, dryRun, json };
}

function command(name, args, options = {}) {
    const result = spawnSync(name, args, {
        cwd: repoRoot,
        env: options.env ?? process.env,
        encoding: "utf8",
        stdio: options.stdio ?? "pipe",
    });
    if (result.error) fail("COMMAND_UNAVAILABLE", `cannot start ${name}`, 2);
    return result;
}

function lines(output) {
    return output
        .split("\n")
        .map((line) => line.trim())
        .filter(Boolean);
}

const input = parseArgs(process.argv.slice(2));
const revision = command("git", ["rev-parse", "--verify", "--end-of-options", `${input.base}^{commit}`]);
if (revision.status !== 0) fail("INVALID_BASE", `Git cannot resolve ${input.base}`, 2);

const committed = command("git", ["diff", "--name-only", "--diff-filter=ACMR", `${input.base}...HEAD`, "--"]);
if (committed.status !== 0) fail("GIT_DIFF_FAILED", "cannot compare the base to HEAD", 2);
const unstaged = command("git", ["diff", "--name-only", "--diff-filter=ACMR", "--"]);
const staged = command("git", ["diff", "--cached", "--name-only", "--diff-filter=ACMR", "--"]);
const untracked = command("git", ["ls-files", "--others", "--exclude-standard"]);
for (const result of [unstaged, staged, untracked]) {
    if (result.status !== 0) fail("GIT_DIFF_FAILED", "cannot inspect working-tree changes", 2);
}

let catalog;
try {
    catalog = JSON.parse(readFileSync(catalogPath, "utf8"));
} catch {
    fail("INVALID_CATALOG", "cannot read config/test-suites.json", 2);
}

const selection = selectAffected({
    changedPaths: [
        ...lines(committed.stdout),
        ...lines(unstaged.stdout),
        ...lines(staged.stdout),
        ...lines(untracked.stdout),
    ],
    catalog,
    repoRoot,
});

if (input.json) {
    console.log(JSON.stringify({ schemaVersion: 1, status: "planned", base: input.base, ...selection }, null, 2));
    process.exit(0);
}

console.log(`test:affected: ${selection.changedPaths.length} changed path(s)`);
for (const reason of selection.reasons) {
    console.log(`  ${reason.path}: ${reason.scope} — ${reason.reason}`);
}
if (selection.selectedIds.length === 0) {
    console.log("test:affected: PASS (no classified contract suites selected)");
    process.exit(0);
}
console.log(`test:affected: selected ${selection.selectedIds.join(", ")}`);
if (input.dryRun) {
    console.log("test:affected: DRY RUN");
    process.exit(0);
}

const selected = catalog.suites.filter((suite) => selection.selectedIds.includes(suite.id));
if (selected.some((suite) => suite.fixture === "local-deployment")) {
    const local = command(process.execPath, [resolve(repoRoot, "tools/run-unit-tests.mjs")], { stdio: "inherit" });
    if (local.status !== 0) fail("LOCAL_TESTS_FAILED", `local runner exited with ${local.status}`, local.status ?? 1);
}

const forkGroups = new Map();
for (const suite of selected.filter((entry) => entry.fixture !== "local-deployment")) {
    const key = `${suite.chainId}:${suite.group}:${suite.block}`;
    forkGroups.set(key, suite);
}
for (const suite of forkGroups.values()) {
    const fork = command(
        process.execPath,
        [
            resolve(repoRoot, "tools/run-fork-tests.mjs"),
            "--chain",
            String(suite.chainId),
            "--suite",
            suite.group,
            "--block",
            String(suite.block),
        ],
        { stdio: "inherit" },
    );
    if (fork.status !== 0) fail("FORK_TESTS_FAILED", `fork runner exited with ${fork.status}`, fork.status ?? 1);
}

console.log(`test:affected: PASS (${selection.selectedIds.length} classified suite(s))`);

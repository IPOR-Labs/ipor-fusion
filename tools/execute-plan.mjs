#!/usr/bin/env node
// Sends exactly one approved plan, within an explicit scope, recording it in the
// journal before and after.
//
// Usage:
//   node tools/execute-plan.mjs --plan <plan.json> --scope <scope.json>
//                               --account <keystore account> [--password-file <path>]
//                               [--rpc-url <url>] [--skip-preflight-simulation]
//   node tools/execute-plan.mjs --plan <plan.json> --scope <scope.json>
//                               --fork-unlocked --rpc-url <local fork>
//
// Exit codes: 0 sent and settled, 1 refused or unresolved, 2 bad arguments.
//
// Signing happens outside this repository: the key lives in a Foundry keystore
// account, and `cast` is invoked with the account name only. No private key, no
// mnemonic and no password is ever taken from an argument, printed, or written
// to the journal — a `--private-key` argument is rejected outright, because
// process arguments are visible to other users on the machine.

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { relative, resolve } from "node:path";
import { repoRoot } from "./lib/vault-config.mjs";
import { firstArtifactError } from "./lib/artifact-schema.mjs";

const journalTool = resolve(repoRoot, "tools/execution-journal.mjs");
const preflightTool = resolve(repoRoot, "tools/preflight-plan.mjs");

function die(code, message) {
    console.error(`vault:execute: ${code}: ${message}`);
    process.exit(code === "INVALID_ARGUMENT" ? 2 : 1);
}

function parseArgs(argv) {
    const values = {};
    const rest = [];
    for (const arg of argv) {
        if (/^--private-key/.test(arg) || /^--mnemonic/.test(arg) || /^--interactive/.test(arg)) {
            die("KEY_IN_ARGUMENT", "keys must not be passed as arguments; import a keystore account and use --account");
        }
        if (arg === "--fork-unlocked" || arg === "--skip-preflight-simulation") values[arg] = true;
        else rest.push(arg);
    }
    for (let index = 0; index < rest.length; index += 2) {
        const flag = rest[index];
        const value = rest[index + 1];
        if (!value || !["--plan", "--scope", "--account", "--password-file", "--rpc-url"].includes(flag)) {
            die("INVALID_ARGUMENT", "expected --plan <file> --scope <file> and either --account <name> or --fork-unlocked");
        }
        values[flag] = value;
    }
    for (const flag of ["--plan", "--scope"]) {
        if (!values[flag]) die("INVALID_ARGUMENT", `missing ${flag}`);
    }
    if (!values["--account"] && !values["--fork-unlocked"]) {
        die("INVALID_ARGUMENT", "either --account <keystore account> or --fork-unlocked is required");
    }
    if (values["--account"] && values["--fork-unlocked"]) {
        die("INVALID_ARGUMENT", "--account and --fork-unlocked are mutually exclusive");
    }
    if (values["--fork-unlocked"] && !values["--rpc-url"]) {
        die("INVALID_ARGUMENT", "--fork-unlocked needs the local fork's --rpc-url");
    }
    return values;
}

const args = parseArgs(process.argv.slice(2));
const planPath = resolve(args["--plan"]);
const scopePath = resolve(args["--scope"]);

const read = (path, code) => {
    try {
        return JSON.parse(readFileSync(path, "utf8"));
    } catch (error) {
        die(code, `cannot read ${path}: ${error.message}`);
    }
};

const plan = read(planPath, "PLAN_UNREADABLE");
const scope = read(scopePath, "SCOPE_UNREADABLE");
const planError = firstArtifactError(plan, "vault-creation");
if (planError) die("INVALID_PLAN", `${relative(repoRoot, planPath)} ${planError}`);

// The scope is the authorization: anything outside it is refused, whatever the
// plan says and whoever produced it.
const selector = plan.transaction.data.slice(0, 10);
const inScope = [
    ["chain", plan.chainId === scope.chainId, `${plan.chainId}`, `${scope.chainId}`],
    [
        "target",
        scope.allowedTargets.some((address) => address.toLowerCase() === plan.transaction.to.toLowerCase()),
        plan.transaction.to,
        scope.allowedTargets.join(", "),
    ],
    ["selector", scope.allowedSelectors.includes(selector), selector, scope.allowedSelectors.join(", ")],
    [
        "sender",
        scope.allowedSenders.some((address) => address.toLowerCase() === plan.transaction.from.toLowerCase()),
        plan.transaction.from,
        scope.allowedSenders.join(", "),
    ],
    ["value", BigInt(plan.transaction.value) <= BigInt(scope.maxValueWei), plan.transaction.value, scope.maxValueWei],
];
for (const [name, ok, observed, allowed] of inScope) {
    if (!ok) die("OUT_OF_SCOPE", `${name} ${observed} is not allowed by ${relative(repoRoot, scopePath)} (${allowed})`);
}

const node = (tool, toolArgs) =>
    spawnSync(process.execPath, [tool, ...toolArgs], { cwd: repoRoot, encoding: "utf8", env: process.env });

// 1. The plan must still hold right now.
const preflightArgs = ["--plan", planPath];
if (args["--rpc-url"]) preflightArgs.push("--skip-simulation");
else if (args["--skip-preflight-simulation"]) preflightArgs.push("--skip-simulation");
const preflight = node(preflightTool, preflightArgs);
process.stdout.write(preflight.stdout);
if (preflight.status !== 0) die("PREFLIGHT_STOP", "the preflight did not return go; nothing was sent");

// 2. Record the intent before anything leaves this machine.
const recordArgs = ["record", "--plan", planPath];
if (args["--rpc-url"]) recordArgs.push("--rpc-url", args["--rpc-url"]);
const recorded = node(journalTool, recordArgs);
process.stdout.write(recorded.stdout);
if (recorded.status !== 0) {
    process.stderr.write(recorded.stderr);
    die("JOURNAL_REFUSED", "the journal did not accept this send");
}
const id = /prepared (\S+)/.exec(recorded.stdout)?.[1];
if (!id) die("JOURNAL_REFUSED", "the journal did not return an entry id");

// 3. Send. The signer is named, never carried.
const sendArgs = ["send", plan.transaction.to, "--json", "--value", plan.transaction.value];
if (args["--rpc-url"]) sendArgs.push("--rpc-url", args["--rpc-url"]);
if (scope.maxGas) sendArgs.push("--gas-limit", String(scope.maxGas));
if (args["--fork-unlocked"]) {
    sendArgs.push("--unlocked", "--from", plan.transaction.from);
} else {
    sendArgs.push("--account", args["--account"], "--from", plan.transaction.from);
    if (args["--password-file"]) sendArgs.push("--password-file", args["--password-file"]);
}
// The calldata comes from the plan verbatim; nothing here rebuilds it.
sendArgs.push(plan.transaction.data);

const sent = spawnSync("cast", sendArgs, { cwd: repoRoot, encoding: "utf8" });
if (sent.status !== 0) {
    // The node's own message is the only clue; it never contains key material.
    process.stderr.write(sent.stderr);
    // The answer may be lost rather than absent, so the journal is told the truth.
    node(journalTool, ["sent", "--id", id, "--no-response"]);
    console.error(`vault:execute: SEND_FAILED: entry ${id} is now "unknown"`);
    console.error(`  resolve it with: npm run vault:journal -- sync --id ${id}`);
    console.error("  do not run this command again until that entry is settled");
    process.exit(1);
}

const receipt = JSON.parse(sent.stdout);
node(journalTool, ["sent", "--id", id, "--tx", receipt.transactionHash]);

// 4. Settle the entry from the chain, not from the send's own answer.
const syncArgs = ["sync", "--id", id];
if (args["--rpc-url"]) syncArgs.push("--rpc-url", args["--rpc-url"]);
const synced = node(journalTool, syncArgs);
process.stdout.write(synced.stdout);
process.exit(synced.status === 0 ? 0 : 1);

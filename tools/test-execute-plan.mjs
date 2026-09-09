import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { parse as parseEnv } from "dotenv";
import { test } from "node:test";
import { startFork } from "./lib/fork.mjs";
import { rpc } from "./lib/chain.mjs";

const repoRoot = resolve(import.meta.dirname, "..");
const executor = resolve(repoRoot, "tools/execute-plan.mjs");
const planner = resolve(repoRoot, "tools/plan-vault.mjs");
const example = resolve(repoRoot, "config/vaults/example.json");
const scope = resolve(repoRoot, "config/execution/scope.example.json");
const block = 25937526;

function provider() {
    if (process.env.ETHEREUM_PROVIDER_URL) return process.env.ETHEREUM_PROVIDER_URL;
    try {
        // FUSION_ENV_FILE mirrors what the tools honour, so a run configured
        // without a provider skips instead of failing on a stale .env.
        return parseEnv(readFileSync(process.env.FUSION_ENV_FILE ?? resolve(repoRoot, ".env"))).ETHEREUM_PROVIDER_URL;
    } catch {
        return undefined;
    }
}

function run(script, args, env = {}) {
    return new Promise((done) => {
        const child = spawn(process.execPath, [script, ...args], { cwd: repoRoot, env: { ...process.env, ...env } });
        let stdout = "";
        let stderr = "";
        child.stdout.on("data", (chunk) => (stdout += chunk));
        child.stderr.on("data", (chunk) => (stderr += chunk));
        child.on("close", (status) => done({ status, stdout, stderr }));
    });
}

function journalEntries(scratch) {
    try {
        return readdirSync(resolve(scratch, "journal"));
    } catch {
        return [];
    }
}

function scopeVariant(directory, change) {
    const value = JSON.parse(readFileSync(scope, "utf8"));
    change(value);
    const path = resolve(directory, "scope.json");
    writeFileSync(path, `${JSON.stringify(value, null, 4)}\n`);
    return path;
}

test("a key passed as an argument is refused before anything else happens", async () => {
    const result = await run(executor, ["--plan", "x", "--scope", "y", "--private-key", "0xdeadbeef"]);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /KEY_IN_ARGUMENT/);
    assert.match(result.stderr, /keystore account/);

    const mnemonic = await run(executor, ["--plan", "x", "--scope", "y", "--mnemonic", "test test"]);
    assert.equal(mnemonic.status, 1);
    assert.match(mnemonic.stderr, /KEY_IN_ARGUMENT/);
});

test("arguments without a signer or with two signers are refused", async () => {
    const none = await run(executor, ["--plan", example, "--scope", scope]);
    assert.equal(none.status, 2);
    assert.match(none.stderr, /--account .* or --fork-unlocked/);

    const both = await run(executor, [
        "--plan", example, "--scope", scope, "--account", "pilot", "--fork-unlocked", "--rpc-url", "http://127.0.0.1:1",
    ]);
    assert.equal(both.status, 2);
    assert.match(both.stderr, /mutually exclusive/);
});

test("only the approved plan, within its scope, is executed", async (t) => {
    const url = provider();
    if (!url) return t.skip("ETHEREUM_PROVIDER_URL is not configured");

    const scratch = mkdtempSync(resolve(tmpdir(), "fusion-execute-"));
    const env = { FUSION_JOURNAL_DIR: resolve(scratch, "journal") };
    const fork = await startFork({ url, blockNumber: block, chainId: 1 });
    try {
        const planPath = resolve(scratch, "plan.json");
        assert.equal((await run(planner, ["--config", example, "--block", String(block), "--out", planPath])).status, 0);

        // The fork stands in for a funded, authorised sender.
        await rpc(fork.url, "anvil_impersonateAccount", ["0x1111111111111111111111111111111111111111"]);
        await rpc(fork.url, "anvil_setBalance", ["0x1111111111111111111111111111111111111111", "0xde0b6b3a7640000"]);

        // out of scope: another target, another selector, another sender
        for (const [name, change, expected] of [
            ["target", (value) => (value.allowedTargets = ["0x3333333333333333333333333333333333333333"]), /OUT_OF_SCOPE: target/],
            ["selector", (value) => (value.allowedSelectors = ["0xdeadbeef"]), /OUT_OF_SCOPE: selector/],
            ["sender", (value) => (value.allowedSenders = ["0x3333333333333333333333333333333333333333"]), /OUT_OF_SCOPE: sender/],
            ["chain", (value) => (value.chainId = 42161), /OUT_OF_SCOPE: chain/],
        ]) {
            const path = scopeVariant(scratch, change);
            const result = await run(
                executor,
                ["--plan", planPath, "--scope", path, "--fork-unlocked", "--rpc-url", fork.url],
                env,
            );
            assert.equal(result.status, 1, `${name} was not refused`);
            assert.match(result.stderr, expected);
        }
        // Nothing was recorded, because nothing was allowed.
        assert.deepEqual(journalEntries(scratch), []);

        // in scope: the plan runs, the journal settles, and the key never appears
        const result = await run(
            executor,
            ["--plan", planPath, "--scope", scope, "--fork-unlocked", "--rpc-url", fork.url],
            env,
        );
        assert.equal(result.status, 0, result.stderr);
        assert.match(result.stdout, /vault:preflight: go/);
        assert.match(result.stdout, /vault:journal: prepared/);
        assert.match(result.stdout, /vault:journal: confirmed/);
        assert.doesNotMatch(result.stdout + result.stderr, /private[- ]key|mnemonic|password/i);

        const entries = journalEntries(scratch);
        assert.equal(entries.length, 1);
        const entry = JSON.parse(readFileSync(resolve(scratch, "journal", entries[0]), "utf8"));
        assert.equal(entry.state, "confirmed");
        assert.match(entry.txHash, /^0x[0-9a-f]{64}$/);
        assert.deepEqual(
            entry.history.map((step) => step.state),
            ["prepared", "pending", "confirmed"],
        );
        // The journal holds a hash of the calldata, never a key or the calldata itself.
        assert.ok(!("privateKey" in entry) && !("data" in entry.transaction));

        // a second run for the same settled plan is allowed only because the first settled
        const again = await run(
            executor,
            ["--plan", planPath, "--scope", scope, "--fork-unlocked", "--rpc-url", fork.url],
            env,
        );
        assert.equal(again.status, 0, again.stderr);
        assert.equal(journalEntries(scratch).length, 2);
    } finally {
        fork.stop();
        rmSync(scratch, { recursive: true, force: true });
    }
});

test("a plan the preflight stops is never sent", async (t) => {
    const url = provider();
    if (!url) return t.skip("ETHEREUM_PROVIDER_URL is not configured");

    const scratch = mkdtempSync(resolve(tmpdir(), "fusion-execute-stop-"));
    const env = { FUSION_JOURNAL_DIR: resolve(scratch, "journal") };
    const fork = await startFork({ url, blockNumber: block, chainId: 1 });
    try {
        const planPath = resolve(scratch, "plan.json");
        assert.equal((await run(planner, ["--config", example, "--block", String(block), "--out", planPath])).status, 0);
        const plan = JSON.parse(readFileSync(planPath, "utf8"));
        plan.expected.feePackage.managementFeeBps = 7;
        writeFileSync(planPath, `${JSON.stringify(plan, null, 4)}\n`);

        const result = await run(
            executor,
            ["--plan", planPath, "--scope", scope, "--fork-unlocked", "--rpc-url", fork.url],
            env,
        );
        assert.equal(result.status, 1);
        assert.match(result.stderr, /PREFLIGHT_STOP/);
        assert.match(result.stdout, /STOP fees\.values/);
        assert.deepEqual(journalEntries(scratch), [], "a stopped plan must not be recorded as prepared");
    } finally {
        fork.stop();
        rmSync(scratch, { recursive: true, force: true });
    }
});

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { parse as parseEnv } from "dotenv";
import { test } from "node:test";
import { startFork } from "./lib/fork.mjs";
import { rpc } from "./lib/chain.mjs";

const repoRoot = resolve(import.meta.dirname, "..");
const journal = resolve(repoRoot, "tools/execution-journal.mjs");
const planner = resolve(repoRoot, "tools/plan-vault.mjs");
const example = resolve(repoRoot, "config/vaults/example.json");
const caller = "0x1111111111111111111111111111111111111111";
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

test("a lost response never turns into a second creation", async (t) => {
    const url = provider();
    if (!url) return t.skip("ETHEREUM_PROVIDER_URL is not configured");

    const scratch = mkdtempSync(resolve(tmpdir(), "fusion-journal-"));
    const env = { FUSION_JOURNAL_DIR: resolve(scratch, "journal") };
    const fork = await startFork({ url, blockNumber: block, chainId: 1 });
    try {
        const planPath = resolve(scratch, "plan.json");
        assert.equal((await run(planner, ["--config", example, "--block", String(block), "--out", planPath])).status, 0);
        const plan = JSON.parse(readFileSync(planPath, "utf8"));

        // 1. prepare
        const prepared = await run(journal, ["record", "--plan", planPath, "--rpc-url", fork.url], env);
        assert.equal(prepared.status, 0, prepared.stderr);
        const id = /prepared (\S+)/.exec(prepared.stdout)[1];

        // 2. the send goes out and the answer is lost
        const lost = await run(journal, ["sent", "--id", id, "--no-response"], env);
        assert.equal(lost.status, 0, lost.stderr);
        assert.match(lost.stdout, /unknown/);

        // 3. preparing the same plan again is refused while that entry is unresolved
        const again = await run(journal, ["record", "--plan", planPath, "--rpc-url", fork.url], env);
        assert.equal(again.status, 1);
        assert.match(again.stderr, /DUPLICATE_IN_FLIGHT/);

        // 4. syncing before anything was mined says so, and refuses to decide
        const early = await run(journal, ["sync", "--id", id, "--rpc-url", fork.url], env);
        assert.equal(early.status, 1);
        assert.match(early.stdout, /has not been used/);
        assert.match(early.stdout, /decision for a person/);

        // 5. the transaction had in fact been mined: the journal finds it by nonce
        await rpc(fork.url, "anvil_impersonateAccount", [caller]);
        await rpc(fork.url, "anvil_setBalance", [caller, "0xde0b6b3a7640000"]);
        const hash = (
            await rpc(fork.url, "eth_sendTransaction", [
                { from: caller, to: plan.transaction.to, data: plan.transaction.data, value: "0x0" },
            ])
        ).result;
        for (let attempt = 0; attempt < 40; attempt += 1) {
            if ((await rpc(fork.url, "eth_getTransactionReceipt", [hash])).result) break;
            await new Promise((wait) => setTimeout(wait, 100));
        }

        const found = await run(journal, ["sync", "--id", id, "--rpc-url", fork.url], env);
        assert.equal(found.status, 0, found.stderr);
        assert.match(found.stdout, /confirmed/);
        assert.match(found.stdout, new RegExp(hash));
        assert.match(found.stdout, /vault:verify/);

        const entry = JSON.parse(readFileSync(resolve(env.FUSION_JOURNAL_DIR, `${id}.json`), "utf8"));
        assert.equal(entry.state, "confirmed");
        assert.equal(entry.txHash, hash);
        assert.equal(entry.nonce, 0);
        assert.deepEqual(
            entry.history.map((step) => step.state),
            ["prepared", "unknown", "confirmed"],
        );

        // 6. a settled entry no longer blocks a new preparation
        const next = await run(journal, ["record", "--plan", planPath, "--rpc-url", fork.url], env);
        assert.equal(next.status, 0, next.stderr);

        const listed = await run(journal, ["list", "--json"], env);
        assert.equal(listed.status, 0);
        const all = JSON.parse(listed.stdout).entries;
        assert.equal(all.length, 2);
        assert.deepEqual(all.map((item) => item.state).sort(), ["confirmed", "prepared"]);
    } finally {
        fork.stop();
        rmSync(scratch, { recursive: true, force: true });
    }
});

test("a known hash is resolved from its receipt, and a reverted one stays reverted", async (t) => {
    const url = provider();
    if (!url) return t.skip("ETHEREUM_PROVIDER_URL is not configured");

    const scratch = mkdtempSync(resolve(tmpdir(), "fusion-journal-revert-"));
    const env = { FUSION_JOURNAL_DIR: resolve(scratch, "journal") };
    const fork = await startFork({ url, blockNumber: block, chainId: 1 });
    try {
        const planPath = resolve(scratch, "plan.json");
        assert.equal((await run(planner, ["--config", example, "--block", String(block), "--out", planPath])).status, 0);
        const plan = JSON.parse(readFileSync(planPath, "utf8"));

        const prepared = await run(journal, ["record", "--plan", planPath, "--rpc-url", fork.url], env);
        const id = /prepared (\S+)/.exec(prepared.stdout)[1];

        await rpc(fork.url, "anvil_impersonateAccount", [caller]);
        await rpc(fork.url, "anvil_setBalance", [caller, "0xde0b6b3a7640000"]);
        // An underlying token with no code makes the creation revert.
        const badData = plan.transaction.data.replace(
            "a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
            "4444444444444444444444444444444444444444",
        );
        const hash = (
            await rpc(fork.url, "eth_sendTransaction", [
                { from: caller, to: plan.transaction.to, data: badData, value: "0x0", gas: "0x2625a0" },
            ])
        ).result;
        for (let attempt = 0; attempt < 40; attempt += 1) {
            if ((await rpc(fork.url, "eth_getTransactionReceipt", [hash])).result) break;
            await new Promise((wait) => setTimeout(wait, 100));
        }

        const sent = await run(journal, ["sent", "--id", id, "--tx", hash], env);
        assert.equal(sent.status, 0, sent.stderr);
        assert.match(sent.stdout, /pending/);

        const synced = await run(journal, ["sync", "--id", id, "--rpc-url", fork.url], env);
        assert.equal(synced.status, 0, synced.stderr);
        assert.match(synced.stdout, /reverted/);

        const entry = JSON.parse(readFileSync(resolve(env.FUSION_JOURNAL_DIR, `${id}.json`), "utf8"));
        assert.equal(entry.state, "reverted");
        assert.equal(entry.result.status, "0x0");
    } finally {
        fork.stop();
        rmSync(scratch, { recursive: true, force: true });
    }
});

test("arguments and unknown entries are named errors", async () => {
    const scratch = mkdtempSync(resolve(tmpdir(), "fusion-journal-args-"));
    const env = { FUSION_JOURNAL_DIR: resolve(scratch, "journal") };
    try {
        assert.equal((await run(journal, ["nonsense"], env)).status, 2);
        assert.equal((await run(journal, ["record"], env)).status, 2);
        const unknown = await run(journal, ["sync", "--id", "no-such-entry"], env);
        assert.equal(unknown.status, 1);
        assert.match(unknown.stderr, /UNKNOWN_ENTRY/);

        const empty = await run(journal, ["list"], env);
        assert.equal(empty.status, 0);
        assert.match(empty.stdout, /the journal is empty/);

        const path = resolve(scratch, "not-a-plan.json");
        writeFileSync(path, JSON.stringify({ kind: "other", status: "planned" }));
        const invalid = await run(journal, ["record", "--plan", path], env);
        assert.equal(invalid.status, 1);
        assert.match(invalid.stderr, /INVALID_PLAN/);
    } finally {
        rmSync(scratch, { recursive: true, force: true });
    }
});

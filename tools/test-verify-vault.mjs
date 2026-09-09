import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { parse as parseEnv } from "dotenv";
import { test } from "node:test";
import { selectCreationLog } from "./lib/creation-log.mjs";
import { startFork } from "./lib/fork.mjs";
import { rpc } from "./lib/chain.mjs";

const repoRoot = resolve(import.meta.dirname, "..");
const verifier = resolve(repoRoot, "tools/verify-vault.mjs");
const planner = resolve(repoRoot, "tools/plan-vault.mjs");
const example = resolve(repoRoot, "config/vaults/example.json");
const factory = "0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852";
const caller = "0x1111111111111111111111111111111111111111";
const block = 25937526;
const topic = "0x9c0af8f185eba94f5cd30afcaee7c849a3ce40571f1f27677b1de7383aa9e78f";

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

function run(script, args) {
    return new Promise((done) => {
        const child = spawn(process.execPath, [script, ...args], { cwd: repoRoot });
        let stdout = "";
        let stderr = "";
        child.stdout.on("data", (chunk) => (stdout += chunk));
        child.stderr.on("data", (chunk) => (stderr += chunk));
        child.on("close", (status) => done({ status, stdout, stderr }));
    });
}

function calldata(underlying) {
    const result = spawnSync(
        "cast",
        [
            "calldata",
            "clone(string,string,address,uint256,address,uint256)",
            "Example USDC Vault",
            "exUSDC",
            underlying,
            "3600",
            "0x2222222222222222222222222222222222222222",
            "0",
        ],
        { cwd: repoRoot, encoding: "utf8" },
    );
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
}

async function send(url, data) {
    await rpc(url, "anvil_impersonateAccount", [caller]);
    await rpc(url, "anvil_setBalance", [caller, "0xde0b6b3a7640000"]);
    const sent = await rpc(url, "eth_sendTransaction", [{ from: caller, to: factory, data, value: "0x0" }]);
    return sent.result;
}

test("only a matching event from the registered factory is used", () => {
    const mine = { address: factory.toLowerCase(), topics: [topic], data: "0x" };
    const foreign = { address: "0x9999999999999999999999999999999999999999", topics: [topic], data: "0x" };
    const other = { address: factory.toLowerCase(), topics: ["0xdead"], data: "0x" };

    assert.equal(selectCreationLog([mine, foreign, other], factory, topic).status, "found");
    assert.equal(selectCreationLog([mine, foreign, other], factory, topic).foreign.length, 1);
    assert.equal(selectCreationLog([foreign], factory, topic).status, "foreign-only");
    assert.equal(selectCreationLog([other], factory, topic).status, "absent");
    assert.equal(selectCreationLog([], factory, topic).status, "absent");
    assert.equal(selectCreationLog([mine, mine], factory, topic).status, "ambiguous");
});

test("bad arguments exit with the input error code", async () => {
    const missing = await run(verifier, ["--chain", "1"]);
    assert.equal(missing.status, 2);
    assert.match(missing.stderr, /INVALID_ARGUMENT: missing --tx/);

    const shortHash = await run(verifier, ["--chain", "1", "--tx", "0x1234"]);
    assert.equal(shortHash.status, 2);
    assert.match(shortHash.stderr, /--tx must be a 32-byte hash/);
});

test("a receipt resolves the real addresses, and pending, revert and finality stay distinct", async (t) => {
    const url = provider();
    if (!url) return t.skip("ETHEREUM_PROVIDER_URL is not configured");

    const fork = await startFork({ url, blockNumber: block, chainId: 1 });
    try {
        // 1. a successful creation
        const hash = await send(fork.url, calldata("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"));
        const ok = await run(verifier, [
            "--chain", "1",
            "--tx", hash,
            "--rpc-url", fork.url,
            "--config", example,
            "--json",
        ]);
        assert.equal(ok.status, 0, ok.stderr);
        const report = JSON.parse(ok.stdout);
        assert.equal(report.status, "success");
        assert.equal(report.deploymentId, "ethereum-fusion-factory-cd05909c");
        assert.match(report.result.instance.plasmaVault, /^0x[0-9a-fA-F]{40}$/);
        assert.equal(report.result.instance.initialOwner, "0x2222222222222222222222222222222222222222");
        assert.equal(report.result.instance.underlyingTokenSymbol, "USDC");
        assert.ok(report.result.instance.withdrawManager, "the withdraw manager was not resolved from the receipt");
        assert.deepEqual(report.result.unresolved, ["contextManager"]);
        assert.equal(report.result.verification.ok, true, JSON.stringify(report.result.verification.checks.filter((c) => !c.ok)));

        // 2. the same receipt without enough confirmations
        const notFinal = await run(verifier, [
            "--chain", "1",
            "--tx", hash,
            "--rpc-url", fork.url,
            "--min-confirmations", "50",
            "--json",
        ]);
        assert.equal(notFinal.status, 0, notFinal.stderr);
        assert.equal(JSON.parse(notFinal.stdout).status, "not-final");

        // 3. a creation that reverts
        const revertHash = await send(fork.url, calldata("0x4444444444444444444444444444444444444444"));
        const reverted = await run(verifier, ["--chain", "1", "--tx", revertHash, "--rpc-url", fork.url, "--json"]);
        assert.equal(reverted.status, 0, reverted.stderr);
        assert.equal(JSON.parse(reverted.stdout).status, "reverted");

        // 4. a transaction that is known but not yet mined
        await rpc(fork.url, "evm_setAutomine", [false]);
        const pendingHash = await send(fork.url, calldata("0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"));
        const pending = await run(verifier, ["--chain", "1", "--tx", pendingHash, "--rpc-url", fork.url, "--json"]);
        assert.equal(pending.status, 0, pending.stderr);
        assert.equal(JSON.parse(pending.stdout).status, "pending");

        // 5. a transaction the endpoint has never seen
        const unknown = await run(verifier, [
            "--chain", "1",
            "--tx", `0x${"ab".repeat(32)}`,
            "--rpc-url", fork.url,
        ]);
        assert.equal(unknown.status, 1);
        assert.match(unknown.stderr, /TRANSACTION_UNKNOWN/);
    } finally {
        fork.stop();
    }
});

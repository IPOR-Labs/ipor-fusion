import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { parse as parseEnv } from "dotenv";
import { test } from "node:test";

const repoRoot = resolve(import.meta.dirname, "..");
const simulator = resolve(repoRoot, "tools/simulate-vault.mjs");
const planner = resolve(repoRoot, "tools/plan-vault.mjs");
const example = resolve(repoRoot, "config/vaults/example.json");
const block = "25937526";

/// The fork tests need a real archive provider; without one they are skipped
/// rather than silently passing.
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

function scratch() {
    return mkdtempSync(resolve(tmpdir(), "fusion-simulate-"));
}

test("bad arguments exit with the input error code", async () => {
    const missing = await run(simulator, []);
    assert.equal(missing.status, 2);
    assert.match(missing.stderr, /INVALID_ARGUMENT: missing --plan/);

    const unreadable = await run(simulator, ["--plan", resolve(repoRoot, "no-such-plan.json")]);
    assert.equal(unreadable.status, 2);
    assert.match(unreadable.stderr, /PLAN_UNREADABLE/);
});

test("an artifact that is not a plan is refused", async () => {
    const directory = scratch();
    try {
        const path = resolve(directory, "plan.json");
        writeFileSync(path, JSON.stringify({ kind: "something-else", status: "planned" }));
        const result = await run(simulator, ["--plan", path]);
        assert.equal(result.status, 1);
        assert.match(result.stderr, /INVALID_PLAN/);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("a missing provider variable is a named error, not a silent skip", async () => {
    const directory = scratch();
    try {
        const path = resolve(directory, "plan.json");
        writeFileSync(
            path,
            JSON.stringify({
                kind: "vault-creation",
                status: "planned",
                chainId: 1,
                readBlock: { number: Number(block) },
                transaction: { to: "0x", from: "0x", data: "0x", value: "0" },
                expected: { implementation: "0x" },
            }),
        );
        const result = await run(simulator, ["--plan", path], {
            FUSION_ENV_FILE: "/dev/null",
            ETHEREUM_PROVIDER_URL: "",
        });
        assert.equal(result.status, 1);
        assert.match(result.stderr, /RPC_UNAVAILABLE.*ETHEREUM_PROVIDER_URL/);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("the planned calldata runs on a fork and reports gas, block and created addresses", async (t) => {
    const url = provider();
    if (!url) return t.skip("ETHEREUM_PROVIDER_URL is not configured");
    const directory = scratch();
    try {
        const planPath = resolve(directory, "plan.json");
        const planned = await run(planner, ["--config", example, "--block", block, "--out", planPath], {
            ETHEREUM_PROVIDER_URL: url,
        });
        assert.equal(planned.status, 0, planned.stderr);

        const result = await run(simulator, ["--plan", planPath], { ETHEREUM_PROVIDER_URL: url });
        assert.equal(result.status, 0, result.stderr);
        const report = JSON.parse(result.stdout);

        assert.equal(report.status, "success");
        assert.equal(report.result.succeeded, true);
        assert.equal(report.fork.broadcast, false);
        assert.equal(report.fork.blockNumber, Number(block));
        assert.match(report.fork.blockHash, /^0x[0-9a-f]{64}$/);
        assert.ok(report.result.gasUsed > 1_000_000, `unexpected gas ${report.result.gasUsed}`);
        assert.match(report.plan.sha256, /^0x[0-9a-f]{64}$/);

        // The event the deployment actually emitted has to agree with the
        // addresses read back from the call.
        assert.equal(report.result.creationEvent.emitter, report.transaction.to);
        assert.equal(report.result.creationEvent.plasmaVault, report.result.created.plasmaVault);
        assert.equal(report.result.created.initialOwner, "0x2222222222222222222222222222222222222222");
        assert.equal(report.result.created.underlyingTokenSymbol, "USDC");

        // The state of the created vault is verified, not assumed from the addresses.
        assert.equal(
            report.result.verification.ok,
            true,
            JSON.stringify(report.result.verification.checks.filter((c) => !c.ok)),
        );
        assert.ok(report.result.verification.checks.length >= 25);

        assert.doesNotMatch(result.stdout + result.stderr, new RegExp(url.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("a caller with code is refused instead of approximated", async (t) => {
    const url = provider();
    if (!url) return t.skip("ETHEREUM_PROVIDER_URL is not configured");
    const directory = scratch();
    try {
        const planPath = resolve(directory, "plan.json");
        const planned = await run(planner, ["--config", example, "--block", block, "--out", planPath], {
            ETHEREUM_PROVIDER_URL: url,
        });
        assert.equal(planned.status, 0, planned.stderr);
        const plan = JSON.parse(readFileSync(planPath, "utf8"));
        // USDC: an address that certainly has code at this block.
        plan.transaction.from = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
        writeFileSync(planPath, JSON.stringify(plan, null, 4));

        const result = await run(simulator, ["--plan", planPath], { ETHEREUM_PROVIDER_URL: url });
        assert.equal(result.status, 1);
        assert.match(result.stderr, /UNSUPPORTED_EXECUTION_PATH/);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("a reverting creation is reported as reverted, not as a failure of the tool", async (t) => {
    const url = provider();
    if (!url) return t.skip("ETHEREUM_PROVIDER_URL is not configured");
    const directory = scratch();
    try {
        const planPath = resolve(directory, "plan.json");
        const planned = await run(planner, ["--config", example, "--block", block, "--out", planPath], {
            ETHEREUM_PROVIDER_URL: url,
        });
        assert.equal(planned.status, 0, planned.stderr);
        const plan = JSON.parse(readFileSync(planPath, "utf8"));
        // An underlying token address with no code cannot be a vault asset.
        const calldata = spawnSync(
            "cast",
            [
                "calldata",
                "clone(string,string,address,uint256,address,uint256)",
                plan.transaction.arguments.assetName,
                plan.transaction.arguments.assetSymbol,
                "0x4444444444444444444444444444444444444444",
                plan.transaction.arguments.redemptionDelayInSeconds,
                plan.transaction.arguments.owner,
                plan.transaction.arguments.daoFeePackageIndex,
            ],
            { cwd: repoRoot, encoding: "utf8" },
        );
        assert.equal(calldata.status, 0, calldata.stderr);
        plan.transaction.data = calldata.stdout.trim();
        writeFileSync(planPath, JSON.stringify(plan, null, 4));

        const result = await run(simulator, ["--plan", planPath], { ETHEREUM_PROVIDER_URL: url });
        assert.equal(result.status, 0, result.stderr);
        const report = JSON.parse(result.stdout);
        assert.equal(report.status, "reverted");
        assert.equal(report.result.succeeded, false);
        assert.equal(report.result.created, null);
        // The reason is decoded, never guessed: a codeless token makes the factory
        // revert without data, and that is what the report says.
        assert.equal(report.result.revertReason.kind, "empty");
        assert.equal(report.result.revertReason.data, "0x");
        assert.match(report.result.revertReason.text, /reverted without data/);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("a plan built for another implementation is refused on the fork", async (t) => {
    const url = provider();
    if (!url) return t.skip("ETHEREUM_PROVIDER_URL is not configured");
    const directory = scratch();
    try {
        const planPath = resolve(directory, "plan.json");
        const planned = await run(planner, ["--config", example, "--block", block, "--out", planPath], {
            ETHEREUM_PROVIDER_URL: url,
        });
        assert.equal(planned.status, 0, planned.stderr);
        const plan = JSON.parse(readFileSync(planPath, "utf8"));
        plan.expected.implementation = "0x3333333333333333333333333333333333333333";
        writeFileSync(planPath, JSON.stringify(plan, null, 4));

        const result = await run(simulator, ["--plan", planPath], { ETHEREUM_PROVIDER_URL: url });
        assert.equal(result.status, 1);
        assert.match(result.stderr, /IMPLEMENTATION_MISMATCH/);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { parse as parseEnv } from "dotenv";
import { test } from "node:test";

const repoRoot = resolve(import.meta.dirname, "..");
const preflight = resolve(repoRoot, "tools/preflight-plan.mjs");
const planner = resolve(repoRoot, "tools/plan-vault.mjs");
const example = resolve(repoRoot, "config/vaults/example.json");
const block = "25937526";

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

let scratch;
let planPath;

test("bad arguments and non-plans exit before reading anything", async () => {
    const missing = await run(preflight, []);
    assert.equal(missing.status, 2);
    assert.match(missing.stderr, /INVALID_ARGUMENT: missing --plan/);

    const directory = mkdtempSync(resolve(tmpdir(), "fusion-preflight-"));
    try {
        const path = resolve(directory, "not-a-plan.json");
        writeFileSync(path, JSON.stringify({ kind: "something", status: "planned" }));
        const result = await run(preflight, ["--plan", path]);
        assert.equal(result.status, 1);
        assert.match(result.stderr, /INVALID_PLAN/);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("a plan that still matches the chain passes, and each change stops it", async (t) => {
    const url = provider();
    if (!url) return t.skip("ETHEREUM_PROVIDER_URL is not configured");

    scratch = mkdtempSync(resolve(tmpdir(), "fusion-preflight-plan-"));
    planPath = resolve(scratch, "plan.json");
    try {
        const built = await run(planner, ["--config", example, "--block", block, "--out", planPath]);
        assert.equal(built.status, 0, built.stderr);

        const ok = await run(preflight, ["--plan", planPath, "--block", block, "--skip-simulation", "--json"]);
        assert.equal(ok.status, 0, ok.stderr);
        const report = JSON.parse(ok.stdout);
        assert.equal(report.status, "go");
        assert.ok(report.checks.every((check) => check.ok));
        assert.ok(report.residualRisk.length >= 3, "the residual risk must stay in the report");
        assert.equal(report.simulation, null);

        const original = JSON.parse(readFileSync(planPath, "utf8"));
        const scenarios = [
            { name: "another implementation", change: (plan) => (plan.expected.implementation = "0x3333333333333333333333333333333333333333"), check: "identity.implementation" },
            { name: "another factory version", change: (plan) => (plan.expected.factoryVersion = "7"), check: "identity.version" },
            { name: "another management fee", change: (plan) => (plan.expected.feePackage.managementFeeBps = 7), check: "fees.values" },
            { name: "another fee recipient", change: (plan) => (plan.expected.feePackage.feeRecipient = "0x3333333333333333333333333333333333333333"), check: "fees.recipient" },
            { name: "another package list", change: (plan) => (plan.expected.feePackage.source = "business-client"), check: "fees.source" },
            { name: "a package index that does not exist", change: (plan) => (plan.expected.feePackage.index = 9), check: "fees.index" },
            { name: "an input file that changed since planning", change: (plan) => (plan.input.sha256 = `0x${"11".repeat(32)}`), check: "input.unchanged" },
            { name: "a caller that is a contract", change: (plan) => (plan.transaction.from = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"), check: "caller.shape" },
        ];

        for (const scenario of scenarios) {
            const plan = JSON.parse(JSON.stringify(original));
            scenario.change(plan);
            writeFileSync(planPath, `${JSON.stringify(plan, null, 4)}\n`);
            const result = await run(preflight, ["--plan", planPath, "--block", block, "--skip-simulation", "--json"]);
            assert.equal(result.status, 1, `${scenario.name} was not stopped`);
            const stopped = JSON.parse(result.stdout);
            assert.equal(stopped.status, "stop");
            assert.deepEqual(
                stopped.checks.filter((check) => !check.ok).map((check) => check.id),
                [scenario.check],
                `unexpected failing checks for ${scenario.name}`,
            );
        }

        // A plan built too long ago is stopped on age alone.
        writeFileSync(planPath, `${JSON.stringify(original, null, 4)}\n`);
        const stale = await run(preflight, [
            "--plan", planPath,
            "--block", String(Number(block) + 500),
            "--max-age-blocks", "10",
            "--skip-simulation",
            "--json",
        ]);
        assert.equal(stale.status, 1);
        assert.deepEqual(
            JSON.parse(stale.stdout).checks.filter((check) => !check.ok).map((check) => check.id),
            ["plan.age"],
        );
    } finally {
        rmSync(scratch, { recursive: true, force: true });
    }
});

test("the preflight re-simulates the plan at the state it just read", async (t) => {
    const url = provider();
    if (!url) return t.skip("ETHEREUM_PROVIDER_URL is not configured");

    const directory = mkdtempSync(resolve(tmpdir(), "fusion-preflight-sim-"));
    try {
        const path = resolve(directory, "plan.json");
        const built = await run(planner, ["--config", example, "--block", block, "--out", path]);
        assert.equal(built.status, 0, built.stderr);

        const result = await run(preflight, ["--plan", path, "--block", block, "--json"]);
        assert.equal(result.status, 0, result.stderr);
        const report = JSON.parse(result.stdout);
        assert.equal(report.status, "go");
        assert.equal(report.simulation.status, "success");
        assert.equal(report.simulation.blockNumber, Number(block));
        assert.equal(report.simulation.verified, true);
        assert.ok(report.checks.some((check) => check.id === "simulation.current" && check.ok));
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("no provider URL reaches the report", async (t) => {
    const url = provider();
    if (!url) return t.skip("ETHEREUM_PROVIDER_URL is not configured");
    const directory = mkdtempSync(resolve(tmpdir(), "fusion-preflight-secret-"));
    try {
        const path = resolve(directory, "plan.json");
        await run(planner, ["--config", example, "--block", block, "--out", path]);
        const result = await run(preflight, ["--plan", path, "--block", block, "--skip-simulation", "--json"]);
        assert.doesNotMatch(result.stdout + result.stderr, new RegExp(url.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
        assert.match(result.stdout, /ETHEREUM_PROVIDER_URL/);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

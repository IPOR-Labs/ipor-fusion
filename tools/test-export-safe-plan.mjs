import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { parse as parseEnv } from "dotenv";
import { test } from "node:test";
import { compareFeeResolution, safeBatch } from "./lib/safe-plan.mjs";

const repoRoot = resolve(import.meta.dirname, "..");
const exporter = resolve(repoRoot, "tools/export-safe-plan.mjs");
const planner = resolve(repoRoot, "tools/plan-vault.mjs");
const example = resolve(repoRoot, "config/vaults/example.json");
const safeAddress = "0xF6a9bd8F6DC537675D499Ac1CA14f2c55d8b5569";
const ownerEoa = "0x2222222222222222222222222222222222222222";
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

const resolution = (overrides = {}) => ({
    caller: safeAddress,
    source: "dao-global",
    index: 0,
    managementFeeBps: 5,
    performanceFeeBps: 1000,
    feeRecipient: safeAddress,
    ...overrides,
});

test("the fee comparison reports every way a Safe can differ from an EOA", () => {
    assert.deepEqual(compareFeeResolution(resolution(), resolution({ caller: ownerEoa })), {
        differs: false,
        differences: [],
    });

    const otherList = compareFeeResolution(resolution({ source: "business-client" }), resolution());
    assert.equal(otherList.differs, true);
    assert.deepEqual(otherList.differences.map((entry) => entry.field), ["source"]);

    const everything = compareFeeResolution(
        resolution({ source: "business-client", managementFeeBps: 30, performanceFeeBps: 200, feeRecipient: ownerEoa }),
        resolution(),
    );
    assert.equal(everything.differs, true);
    assert.deepEqual(everything.differences.map((entry) => entry.field), [
        "source",
        "managementFeeBps",
        "performanceFeeBps",
        "feeRecipient",
    ]);

    // Address case must not be mistaken for a difference.
    assert.equal(
        compareFeeResolution(resolution({ feeRecipient: safeAddress.toLowerCase() }), resolution()).differs,
        false,
    );
});

test("the batch document is a Safe Transaction Builder file for exactly one call", () => {
    const batch = safeBatch({
        chainId: 1,
        safe: safeAddress,
        to: "0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852",
        value: "0",
        data: "0x8697b10a",
        name: "Create Fusion vault",
        description: "from a plan",
        createdAt: 1,
    });
    assert.equal(batch.version, "1.0");
    assert.equal(batch.chainId, "1");
    assert.equal(batch.meta.createdFromSafeAddress, safeAddress);
    assert.equal(batch.transactions.length, 1);
    assert.equal(batch.transactions[0].value, "0");
    assert.equal(batch.transactions[0].data, "0x8697b10a");
});

test("a plan whose caller is an EOA cannot be exported for a Safe", async (t) => {
    const url = provider();
    if (!url) return t.skip("ETHEREUM_PROVIDER_URL is not configured");
    const scratch = mkdtempSync(resolve(tmpdir(), "fusion-safe-eoa-"));
    try {
        const planPath = resolve(scratch, "plan.json");
        assert.equal((await run(planner, ["--config", example, "--block", String(block), "--out", planPath])).status, 0);
        const result = await run(exporter, ["--plan", planPath]);
        assert.equal(result.status, 1);
        assert.match(result.stderr, /CALLER_NOT_A_CONTRACT/);
    } finally {
        rmSync(scratch, { recursive: true, force: true });
    }
});

test("a Safe plan is exported, compared with the owner EOA and simulated as the Safe", async (t) => {
    const url = provider();
    if (!url) return t.skip("ETHEREUM_PROVIDER_URL is not configured");

    const scratch = mkdtempSync(resolve(tmpdir(), "fusion-safe-"));
    try {
        const config = JSON.parse(readFileSync(example, "utf8"));
        config.caller = safeAddress;
        config.vault.name = "Safe Created USDC Vault";
        config.vault.symbol = "sfUSDC";
        const configPath = resolve(scratch, "safe-config.json");
        writeFileSync(configPath, `${JSON.stringify(config, null, 4)}\n`);

        const planPath = resolve(scratch, "plan.json");
        assert.equal((await run(planner, ["--config", configPath, "--block", String(block), "--out", planPath])).status, 0);
        const batchPath = resolve(scratch, "batch.json");

        const result = await run(exporter, [
            "--plan", planPath,
            "--compare-with", ownerEoa,
            "--out", batchPath,
            "--json",
        ]);
        assert.equal(result.status, 0, result.stderr);
        const report = JSON.parse(result.stdout);

        assert.equal(report.status, "exported");
        assert.equal(report.safe, safeAddress);
        assert.equal(report.simulation.callerIsTheSafe, true);
        assert.equal(report.simulation.succeeded, true);
        assert.equal(report.simulation.broadcast, false);
        assert.ok(report.simulation.gasUsed > 1_000_000);

        // The fees are resolved for the Safe's own address, not the owner's.
        assert.equal(report.fees.safe.caller, safeAddress);
        assert.equal(report.fees.comparedWith.with, ownerEoa);
        assert.equal(typeof report.fees.comparedWith.differs, "boolean");

        const batch = JSON.parse(readFileSync(batchPath, "utf8"));
        assert.equal(batch.transactions.length, 1);
        assert.equal(batch.meta.createdFromSafeAddress, safeAddress);
        const plan = JSON.parse(readFileSync(planPath, "utf8"));
        assert.equal(batch.transactions[0].data, plan.transaction.data, "the batch must carry the plan's calldata verbatim");
        assert.equal(batch.transactions[0].to, plan.transaction.to);

        assert.ok(report.warnings.some((warning) => /threshold|execTransaction/.test(warning)));
        assert.ok(report.warnings.some((warning) => /proposed or published/.test(warning)));
    } finally {
        rmSync(scratch, { recursive: true, force: true });
    }
});

test("bad arguments exit with the input error code", async () => {
    assert.equal((await run(exporter, [])).status, 2);
    const badAddress = await run(exporter, ["--plan", example, "--compare-with", "0x1234"]);
    assert.equal(badAddress.status, 2);
    assert.match(badAddress.stderr, /--compare-with must be a 20-byte address/);
});

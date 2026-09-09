import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const doctor = resolve(repoRoot, "tools/agent-doctor.mjs");

function invoke(args = [], env = {}) {
    return spawnSync(process.execPath, [doctor, ...args], {
        cwd: repoRoot,
        env: { ...process.env, ...env },
        encoding: "utf8",
    });
}

test("JSON mode is structured and never exposes RPC values", () => {
    const secret = "https://rpc.invalid/private-test-token";
    const result = invoke(["--json"], { ETHEREUM_PROVIDER_URL: secret });
    assert.equal(result.status, 0, result.stderr);
    const report = JSON.parse(result.stdout);
    assert.equal(report.schemaVersion, 1);
    assert.equal(report.networkChecks, false);
    assert.ok(["ok", "warning"].includes(report.status));
    assert.ok(report.checks.some((check) => check.id === "foundry-version" && check.status === "ok"));
    assert.doesNotMatch(result.stdout, /private-test-token/);
    assert.doesNotMatch(result.stderr, /private-test-token/);
});

test("text mode reports variable names and not their values", () => {
    const secret = "rpc-value-must-not-appear";
    const result = invoke([], { BASE_PROVIDER_URL: secret });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /env:BASE_PROVIDER_URL: BASE_PROVIDER_URL is set/);
    assert.doesNotMatch(result.stdout, new RegExp(secret));
});

test("a checkout without dependencies fails with the npm ci remediation", () => {
    const directory = mkdtempSync(resolve(tmpdir(), "fusion-doctor-"));
    try {
        writeFileSync(
            resolve(directory, "package.json"),
            JSON.stringify({ engines: { node: process.version.slice(1), npm: "0.0.0" } }),
        );
        writeFileSync(resolve(directory, ".env.example"), "ETHEREUM_PROVIDER_URL=\n");
        const result = invoke(["--json", "--root", directory]);
        assert.equal(result.status, 1);
        const report = JSON.parse(result.stdout);
        const dependencies = report.checks.find((check) => check.id === "node-dependencies");
        assert.equal(dependencies.status, "error");
        assert.equal(dependencies.remediation, "Run npm ci.");
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

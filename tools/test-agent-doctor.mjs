import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
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

function invokeAsync(args = [], env = {}) {
    return new Promise((resolveResult) => {
        const child = spawn(process.execPath, [doctor, ...args], {
            cwd: repoRoot,
            env: { ...process.env, ...env },
        });
        let stdout = "";
        let stderr = "";
        child.stdout.on("data", (chunk) => (stdout += chunk));
        child.stderr.on("data", (chunk) => (stderr += chunk));
        child.on("close", (status) => resolveResult({ status, stdout, stderr }));
    });
}

async function withRpc(handler, callback) {
    const server = createServer((request, response) => {
        let body = "";
        request.on("data", (chunk) => (body += chunk));
        request.on("end", () => {
            response.setHeader("content-type", "application/json");
            response.end(JSON.stringify(handler(JSON.parse(body))));
        });
    });
    await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
    const address = server.address();
    try {
        await callback(`http://127.0.0.1:${address.port}/private-token`);
    } finally {
        await new Promise((resolveClose) => server.close(resolveClose));
    }
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

const rpcArgs = ["--json", "--rpc", "--chain", "1", "--block", "23831825"];

test("RPC unavailable, chain mismatch and missing history are distinct and redacted", async () => {
    const unavailable = await invokeAsync(rpcArgs, {
        ETHEREUM_PROVIDER_URL: "http://127.0.0.1:1/private-token",
    });
    assert.equal(unavailable.status, 1);
    assert.match(unavailable.stdout, /RPC_UNAVAILABLE/);
    assert.doesNotMatch(unavailable.stdout + unavailable.stderr, /private-token|127\\.0\\.0\\.1/);

    await withRpc(
        () => ({ jsonrpc: "2.0", id: 1, result: "0x2" }),
        async (url) => {
            const mismatch = await invokeAsync(rpcArgs, { ETHEREUM_PROVIDER_URL: url });
            assert.equal(mismatch.status, 1);
            assert.match(mismatch.stdout, /CHAIN_MISMATCH/);
            assert.doesNotMatch(mismatch.stdout + mismatch.stderr, /private-token|127\\.0\\.0\\.1/);
        },
    );

    await withRpc(
        (request) =>
            request.method === "eth_chainId"
                ? { jsonrpc: "2.0", id: 1, result: "0x1" }
                : { jsonrpc: "2.0", id: 1, error: { code: -32000, message: "missing trie node" } },
        async (url) => {
            const history = await invokeAsync(rpcArgs, { ETHEREUM_PROVIDER_URL: url });
            assert.equal(history.status, 1);
            assert.match(history.stdout, /HISTORICAL_STATE_UNAVAILABLE/);
            assert.doesNotMatch(history.stdout, /missing trie node|private-token|127\\.0\\.0\\.1/);
        },
    );
});

test("RPC mode accepts matching chain ID and historical contract code", async () => {
    await withRpc(
        (request) => ({
            jsonrpc: "2.0",
            id: 1,
            result: request.method === "eth_chainId" ? "0x1" : "0x60006000",
        }),
        async (url) => {
            const result = await invokeAsync(rpcArgs, { ETHEREUM_PROVIDER_URL: url });
            assert.equal(result.status, 0, result.stderr);
            const report = JSON.parse(result.stdout);
            assert.equal(report.networkChecks, true);
            assert.ok(report.checks.some((check) => check.id === "rpc:1" && check.status === "ok"));
            assert.ok(report.checks.some((check) => check.id === "rpc-history:1" && check.status === "ok"));
            assert.doesNotMatch(result.stdout, /private-token|127\\.0\\.0\\.1/);
        },
    );
});

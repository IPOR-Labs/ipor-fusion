import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { parse as parseEnv } from "dotenv";
import { test } from "node:test";

const repoRoot = resolve(import.meta.dirname, "..");
const server = resolve(repoRoot, "tools/mcp-server.mjs");
const inspector = resolve(repoRoot, "tools/inspect-factory.mjs");

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

/// Sends a batch of requests over stdio and returns the parsed responses.
function talk(requests, env = {}) {
    return new Promise((done) => {
        const child = spawn(process.execPath, [server], { cwd: repoRoot, env: { ...process.env, ...env } });
        let stdout = "";
        child.stdout.on("data", (chunk) => (stdout += chunk));
        child.on("close", () => done(stdout.trim().split("\n").filter(Boolean).map((line) => JSON.parse(line))));
        for (const request of requests) child.stdin.write(`${JSON.stringify(request)}\n`);
        child.stdin.end();
    });
}

const call = (id, name, args) => ({ jsonrpc: "2.0", id, method: "tools/call", params: { name, arguments: args } });
const payload = (response) => JSON.parse(response.result.content[0].text);

test("the server speaks the handshake and exposes exactly two read-only tools", async () => {
    const [initialize, list] = await talk([
        { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
        { jsonrpc: "2.0", id: 2, method: "tools/list" },
    ]);
    assert.equal(initialize.result.protocolVersion, "2024-11-05");
    assert.equal(initialize.result.serverInfo.name, "ipor-fusion-deployments");

    const names = list.result.tools.map((tool) => tool.name).sort();
    assert.deepEqual(names, ["inspect_factory", "list_deployments"]);
    // Nothing that could sign, send, plan an execution or write anything.
    for (const tool of list.result.tools) {
        assert.doesNotMatch(tool.name, /send|sign|execute|broadcast|write|configure|create/i);
    }
});

test("list_deployments answers from the repository's own manifests", async () => {
    const [, all, ethereum, verified] = await talk([
        { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
        call(2, "list_deployments", {}),
        call(3, "list_deployments", { chainId: 1 }),
        call(4, "list_deployments", { status: "verified" }),
    ]);

    const manifest = JSON.parse(readFileSync(resolve(repoRoot, "deployments/1/factories.json"), "utf8"));
    const everything = payload(all);
    assert.ok(everything.count >= manifest.deployments.length);
    assert.ok(everything.deployments.some((entry) => entry.id === manifest.deployments[0].id));

    const onlyEthereum = payload(ethereum);
    assert.ok(onlyEthereum.deployments.every((entry) => entry.chainId === 1));
    assert.equal(onlyEthereum.count, manifest.deployments.length);

    const onlyVerified = payload(verified);
    assert.ok(onlyVerified.deployments.every((entry) => entry.status === "verified"));
    // Every listed entry carries its evidence, not just its address.
    for (const entry of onlyVerified.deployments) {
        assert.ok(entry.verification.reportPath, `${entry.id} has no report path`);
        assert.ok(entry.verification.compatibilityTestPath, `${entry.id} has no compatibility test`);
    }
});

test("an unknown tool and a failing inspection are reported, not thrown away", async () => {
    const [, unknown, failing] = await talk(
        [
            { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
            call(2, "send_transaction", {}),
            call(3, "inspect_factory", {
                chainId: 1,
                deploymentId: "ethereum-fusion-factory-cd05909c",
                block: 25937526,
                caller: "0x1111111111111111111111111111111111111111",
            }),
        ],
        { FUSION_ENV_FILE: "/dev/null", ETHEREUM_PROVIDER_URL: "" },
    );

    assert.equal(unknown.error.code, -32602);
    assert.match(unknown.error.message, /unknown tool: send_transaction/);

    assert.equal(failing.result.isError, true);
    assert.match(failing.result.content[0].text, /RPC_UNAVAILABLE/);
});

test("inspect_factory returns exactly what the CLI returns for the same input", async (t) => {
    const url = provider();
    if (!url) return t.skip("ETHEREUM_PROVIDER_URL is not configured");

    const args = {
        chainId: 1,
        deploymentId: "ethereum-fusion-factory-cd05909c",
        block: 25937526,
        caller: "0x1111111111111111111111111111111111111111",
    };
    const [, response] = await talk([
        { jsonrpc: "2.0", id: 1, method: "initialize", params: {} },
        call(2, "inspect_factory", args),
    ]);
    assert.equal(response.result.isError, false, response.result.content[0].text);

    const cli = spawnSync(
        process.execPath,
        [
            inspector,
            "--chain", String(args.chainId),
            "--deployment", args.deploymentId,
            "--block", String(args.block),
            "--caller", args.caller,
        ],
        { cwd: repoRoot, encoding: "utf8" },
    );
    assert.equal(cli.status, 0, cli.stderr);

    assert.deepEqual(payload(response), JSON.parse(cli.stdout), "MCP and CLI disagree on the same input");
    assert.doesNotMatch(response.result.content[0].text, new RegExp(url.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")));
});

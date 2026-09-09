import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { test } from "node:test";

const repoRoot = resolve(import.meta.dirname, "..");
const inspector = resolve(repoRoot, "tools/inspect-factory.mjs");
const proxy = "0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852";
const implementation = "0xf19c1e9f6616f6056af1e322a86fdaaaaf0263f5";
const args = [
    "--chain",
    "1",
    "--deployment",
    "ethereum-fusion-factory-cd05909c",
    "--block",
    "25937526",
    "--caller",
    "0x1111111111111111111111111111111111111111",
];

function invoke(arguments_, env = {}) {
    return spawnSync(process.execPath, [inspector, ...arguments_], {
        cwd: repoRoot,
        env: { ...process.env, FUSION_ENV_FILE: "/dev/null", ...env },
        encoding: "utf8",
    });
}

function invokeAsync(arguments_, env = {}) {
    return new Promise((resolveResult) => {
        const child = spawn(process.execPath, [inspector, ...arguments_], {
            cwd: repoRoot,
            env: { ...process.env, FUSION_ENV_FILE: "/dev/null", ...env },
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

function rpcResult(result) {
    return { jsonrpc: "2.0", id: 1, result };
}

function commonResponse(request) {
    if (request.method === "eth_chainId") return rpcResult("0x1");
    if (request.method === "eth_getBlockByNumber") {
        return rpcResult({ hash: `0x${"ab".repeat(32)}` });
    }
    return undefined;
}

test("manifest and requested chain mismatch is a named error", () => {
    const chainIndex = args.indexOf("--chain") + 1;
    const mismatched = [...args];
    mismatched[chainIndex] = "2";
    const result = invoke(mismatched);
    assert.equal(result.status, 1);
    assert.match(result.stderr, /CHAIN_MISMATCH/);
});

test("missing proxy code is distinct and provider details remain redacted", async () => {
    await withRpc(
        (request) => commonResponse(request) ?? rpcResult("0x"),
        async (url) => {
            const result = await invokeAsync(args, { ETHEREUM_PROVIDER_URL: url });
            assert.equal(result.status, 1);
            assert.match(result.stderr, /NO_CODE/);
            assert.match(result.stderr, new RegExp(proxy, "i"));
            assert.doesNotMatch(result.stdout + result.stderr, /private-token|127\\.0\\.0\\.1/);
        },
    );
});

test("an unexpected implementation has its own error", async () => {
    await withRpc(
        (request) => {
            const common = commonResponse(request);
            if (common) return common;
            if (request.method === "eth_getCode") return rpcResult("0x6000");
            if (request.method === "eth_getStorageAt") return rpcResult(`0x${"0".repeat(24)}${"22".repeat(20)}`);
            throw new Error(`unexpected method ${request.method}`);
        },
        async (url) => {
            const result = await invokeAsync(args, { ETHEREUM_PROVIDER_URL: url });
            assert.equal(result.status, 1);
            assert.match(result.stderr, /IMPLEMENTATION_MISMATCH/);
            assert.doesNotMatch(result.stderr, /private-token|127\\.0\\.0\\.1/);
        },
    );
});

test("a deployed interface that cannot answer the ABI is an unsupported version", async () => {
    await withRpc(
        (request) => {
            const common = commonResponse(request);
            if (common) return common;
            if (request.method === "eth_getCode") return rpcResult("0x6000");
            if (request.method === "eth_getStorageAt")
                return rpcResult(`0x${"0".repeat(24)}${implementation.slice(2)}`);
            if (request.method === "eth_call") {
                return { jsonrpc: "2.0", id: 1, error: { code: 3, message: "execution reverted: secret" } };
            }
            throw new Error(`unexpected method ${request.method}`);
        },
        async (url) => {
            const result = await invokeAsync(args, { ETHEREUM_PROVIDER_URL: url });
            assert.equal(result.status, 1);
            assert.match(result.stderr, /UNSUPPORTED_FACTORY_VERSION/);
            assert.match(result.stderr, /getFactoryAddresses/);
            assert.doesNotMatch(result.stderr, /secret|private-token|127\\.0\\.0\\.1/);
        },
    );
});

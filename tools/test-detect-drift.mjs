import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createServer } from "node:http";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { test } from "node:test";

const repoRoot = resolve(import.meta.dirname, "..");
const detector = resolve(repoRoot, "tools/detect-drift.mjs");
const realManifest = JSON.parse(readFileSync(resolve(repoRoot, "deployments/1/factories.json"), "utf8"));
const proxy = realManifest.deployments[0].address;
const implementation = realManifest.deployments[0].proxy.implementation;
const realReport = JSON.parse(
    readFileSync(resolve(repoRoot, "deployments/reports/ethereum-fusion-factory-cd05909c-25937526.json"), "utf8"),
);

function cast(args) {
    const result = spawnSync("cast", args, { cwd: repoRoot, encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
}

const selectors = {
    version: cast(["sig", "getFusionFactoryVersion()"]),
    factories: cast(["sig", "getFactoryAddresses()"]),
    bases: cast(["sig", "getBaseAddresses()"]),
};

const components = realReport.reads.components.entries.filter(
    (entry) => entry.kind === "factory" || entry.kind === "base",
);

/// A synthetic chain: fake runtime code for every address, and a confirmed
/// report whose hashes are the hashes of exactly that code. Anything the tests
/// then change on the chain is a real difference from a real recorded state.
const code = new Map([
    [proxy.toLowerCase(), "0x6001"],
    [implementation.toLowerCase(), "0x6002"],
    ...components.map((entry, index) => [entry.address.toLowerCase(), `0x60${(index + 16).toString(16)}`]),
]);
const hashOf = (address) => cast(["keccak", code.get(address.toLowerCase())]);

function registry(scratch) {
    const reportPath = resolve(scratch, "confirmed.json");
    writeFileSync(
        reportPath,
        `${JSON.stringify(
            {
                schemaVersion: 1,
                blockNumber: 25937526,
                identity: {
                    proxy: { address: proxy, runtimeCodeHash: hashOf(proxy) },
                    implementation: { address: implementation, runtimeCodeHash: hashOf(implementation) },
                    reportedFactoryVersion: 8,
                },
                reads: {
                    components: {
                        entries: components.map((entry) => ({ ...entry, runtimeCodeHash: hashOf(entry.address) })),
                    },
                },
            },
            null,
            4,
        )}\n`,
    );

    const manifest = JSON.parse(JSON.stringify(realManifest));
    manifest.deployments[0].verification.reportPath = reportPath;
    mkdirSync(resolve(scratch, "1"), { recursive: true });
    writeFileSync(resolve(scratch, "1/factories.json"), `${JSON.stringify(manifest, null, 4)}\n`);
    return scratch;
}

function invoke(args, env = {}) {
    return new Promise((done) => {
        const child = spawn(process.execPath, [detector, ...args], {
            cwd: repoRoot,
            env: { ...process.env, FUSION_ENV_FILE: "/dev/null", ...env },
        });
        let stdout = "";
        let stderr = "";
        child.stdout.on("data", (chunk) => (stdout += chunk));
        child.stderr.on("data", (chunk) => (stderr += chunk));
        child.on("close", (status) => done({ status, stdout, stderr }));
    });
}

async function withRpc(handler, callback) {
    const server = createServer((request, response) => {
        let body = "";
        request.on("data", (chunk) => (body += chunk));
        request.on("end", () => {
            const answer = handler(JSON.parse(body));
            if (answer === undefined) {
                response.statusCode = 500;
                response.end("{}");
                return;
            }
            response.setHeader("content-type", "application/json");
            response.end(JSON.stringify(answer));
        });
    });
    await new Promise((listening) => server.listen(0, "127.0.0.1", listening));
    try {
        await callback(`http://127.0.0.1:${server.address().port}/private-token`);
    } finally {
        await new Promise((closed) => server.close(closed));
    }
}

const ok = (result) => ({ jsonrpc: "2.0", id: 1, result });

/// A dropped component leaves a zero address in the struct, exactly as an
/// on-chain configuration with one slot cleared would.
const pad = (addresses, size) => [
    ...addresses,
    ...Array.from({ length: Math.max(0, size - addresses.length) }, () => "0x0000000000000000000000000000000000000000"),
];

function chainAt({ slot = implementation, codeMap = code, version = 8, addresses } = {}) {
    const factories = (addresses ?? components).filter((entry) => entry.kind === "factory").map((entry) => entry.address);
    const bases = (addresses ?? components).filter((entry) => entry.kind === "base").map((entry) => entry.address);
    return (request) => {
        if (request.method === "eth_chainId") return ok("0x1");
        if (request.method === "eth_getBlockByNumber") return ok({ hash: `0x${"ab".repeat(32)}`, number: "0x18bc8b0" });
        if (request.method === "eth_getStorageAt") return ok(`0x${"0".repeat(24)}${slot.slice(2)}`);
        if (request.method === "eth_getCode") return ok(codeMap.get(String(request.params[0]).toLowerCase()) ?? "0x");
        if (request.method === "eth_call") {
            const data = request.params[0].data;
            if (data.startsWith(selectors.version)) return ok(cast(["abi-encode", "f(uint256)", String(version)]));
            // The deployed getters return fixed structs, so the fake answers with
            // the same shape: seven factory slots and six base slots.
            if (data.startsWith(selectors.factories)) {
                return ok(cast(["abi-encode", `f((${"address,".repeat(6)}address))`, `(${pad(factories, 7).join(",")})`]));
            }
            if (data.startsWith(selectors.bases)) {
                return ok(cast(["abi-encode", `f((${"address,".repeat(5)}address))`, `(${pad(bases, 6).join(",")})`]));
            }
        }
        return undefined;
    };
}

async function scenario(handler, args = ["--json"]) {
    const scratch = mkdtempSync(resolve(tmpdir(), "fusion-drift-"));
    registry(scratch);
    try {
        let outcome;
        await withRpc(handler, async (url) => {
            outcome = await invoke(args, { ETHEREUM_PROVIDER_URL: url, FUSION_DEPLOYMENTS_DIR: scratch });
        });
        return outcome;
    } finally {
        rmSync(scratch, { recursive: true, force: true });
    }
}

test("a deployment that still matches its confirmed state is unchanged", async () => {
    const result = await scenario(chainAt());
    assert.equal(result.status, 0, result.stderr);
    const report = JSON.parse(result.stdout);
    assert.equal(report.status, "unchanged");
    assert.deepEqual(report.differences, []);
    assert.equal(report.confirmedAt.blockNumber, 25937526);
    assert.equal(report.observedAt.blockNumber, 0x18bc8b0);
    assert.doesNotMatch(result.stdout, /private-token|127\.0\.0\.1/);
});

test("an upgraded implementation is drift, with its own exit code", async () => {
    const upgraded = "0x3333333333333333333333333333333333333333";
    const codeMap = new Map(code);
    codeMap.set(upgraded.toLowerCase(), "0x6009");
    const result = await scenario(chainAt({ slot: upgraded, codeMap }));
    assert.equal(result.status, 1, result.stderr);
    const report = JSON.parse(result.stdout);
    assert.equal(report.status, "drift");
    const fields = report.differences.map((difference) => difference.field);
    assert.ok(fields.includes("proxy.implementation"));
    assert.ok(fields.includes("implementation.runtimeCodeHash"));
    assert.ok(report.warnings.some((warning) => /never promotes/.test(warning)));
});

test("a component that changed code, and one the factory dropped, are both drift", async () => {
    const codeMap = new Map(code);
    const changed = components.find((entry) => entry.kind === "base");
    codeMap.set(changed.address.toLowerCase(), "0xdeadbeef");
    const dropped = components.find((entry) => entry.kind === "factory");
    const result = await scenario(
        chainAt({ codeMap, addresses: components.filter((entry) => entry.id !== dropped.id) }),
    );
    assert.equal(result.status, 1);
    const report = JSON.parse(result.stdout);
    assert.ok(
        report.differences.some((difference) => difference.field === `component.${changed.id}.runtimeCodeHash`),
        JSON.stringify(report.differences),
    );
    assert.ok(
        report.differences.some(
            (difference) => difference.field === `component.${dropped.id}` && difference.observed === "no longer used by the factory",
        ),
    );
});

test("a reported version other than the confirmed one is drift", async () => {
    const result = await scenario(chainAt({ version: 9 }));
    assert.equal(result.status, 1);
    assert.deepEqual(
        JSON.parse(result.stdout).differences.map((difference) => difference.field),
        ["factoryVersion"],
    );
});

test("a provider failure is a third outcome, not drift", async () => {
    const unset = await invoke([], { ETHEREUM_PROVIDER_URL: "" });
    assert.equal(unset.status, 2);
    assert.match(unset.stderr, /RPC_UNAVAILABLE/);

    const noBlock = await scenario((request) => (request.method === "eth_chainId" ? ok("0x1") : undefined), []);
    assert.equal(noBlock.status, 2);
    assert.match(noBlock.stderr, /BLOCK_UNAVAILABLE/);

    const otherChain = await scenario((request) => (request.method === "eth_chainId" ? ok("0xa4b1") : undefined), []);
    assert.equal(otherChain.status, 2);
    assert.match(otherChain.stderr, /CHAIN_MISMATCH/);
});

test("an unknown deployment cannot be compared", async () => {
    const result = await invoke(["--deployment", "ethereum-fusion-factory-unknown"]);
    assert.equal(result.status, 2);
    assert.match(result.stderr, /UNKNOWN_DEPLOYMENT/);
});

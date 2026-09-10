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
const baseManifest = JSON.parse(readFileSync(resolve(repoRoot, "deployments/8453/factories.json"), "utf8"));
const proxy = realManifest.deployments[0].address;
const implementation = realManifest.deployments[0].proxy.implementation;
const realReport = JSON.parse(
    readFileSync(resolve(repoRoot, "deployments/reports/ethereum-fusion-factory-cd05909c-25937526.json"), "utf8"),
);
const pilotSelection = ["--chain", "1", "--deployment", realManifest.deployments[0].id];

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

async function scenario(handler, args = [...pilotSelection, "--json"]) {
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

function batchRegistry(scratch) {
    const states = new Map();
    let codeIndex = 64;
    for (const source of [realManifest, baseManifest]) {
        const manifest = JSON.parse(JSON.stringify(source));
        const state = { deployments: manifest.deployments, code: new Map() };
        states.set(manifest.chainId, state);
        mkdirSync(resolve(scratch, String(manifest.chainId)), { recursive: true });

        for (const deployment of manifest.deployments) {
            const originalReport = JSON.parse(
                readFileSync(resolve(repoRoot, deployment.verification.reportPath), "utf8"),
            );
            const proxyCode = `0x60${codeIndex.toString(16)}`;
            codeIndex += 1;
            const implementationCode = `0x60${codeIndex.toString(16)}`;
            codeIndex += 1;
            state.code.set(deployment.address.toLowerCase(), proxyCode);
            state.code.set(deployment.proxy.implementation.toLowerCase(), implementationCode);

            const reportComponents =
                deployment.kind === "price-feed-factory"
                    ? (originalReport.reads?.components?.entries ?? []).map((component) => {
                          const componentCode = `0x60${codeIndex.toString(16)}`;
                          codeIndex += 1;
                          state.code.set(component.address.toLowerCase(), componentCode);
                          return { ...component, runtimeCodeHash: cast(["keccak", componentCode]) };
                      })
                    : [];

            const reportPath = resolve(scratch, `${deployment.id}.json`);
            writeFileSync(
                reportPath,
                `${JSON.stringify(
                    {
                        schemaVersion: 1,
                        blockNumber: deployment.verification.blockNumber,
                        identity: {
                            proxy: {
                                address: deployment.address,
                                runtimeCodeHash: cast(["keccak", proxyCode]),
                            },
                            implementation: {
                                address: deployment.proxy.implementation,
                                runtimeCodeHash: cast(["keccak", implementationCode]),
                            },
                            reportedFactoryVersion: deployment.interface.reportedVersion,
                        },
                        reads: { components: { entries: reportComponents } },
                    },
                    null,
                    4,
                )}\n`,
            );
            deployment.verification.reportPath = reportPath;
        }
        writeFileSync(
            resolve(scratch, String(manifest.chainId), "factories.json"),
            `${JSON.stringify(manifest, null, 4)}\n`,
        );
    }
    return states;
}

function batchChainAt(chainId, state, codeMap = state.code) {
    return (request) => {
        if (request.method === "eth_chainId") return ok(`0x${chainId.toString(16)}`);
        if (request.method === "eth_getBlockByNumber") {
            return ok({ hash: `0x${chainId.toString(16).padStart(64, "0")}`, number: "0x1e240" });
        }
        if (request.method === "eth_getStorageAt") {
            const address = String(request.params[0]).toLowerCase();
            const deployment = state.deployments.find((entry) => entry.address.toLowerCase() === address);
            if (!deployment) return undefined;
            return ok(`0x${"0".repeat(24)}${deployment.proxy.implementation.slice(2)}`);
        }
        if (request.method === "eth_getCode") {
            return ok(codeMap.get(String(request.params[0]).toLowerCase()) ?? "0x");
        }
        if (request.method === "eth_call") {
            const address = String(request.params[0].to).toLowerCase();
            const deployment = state.deployments.find((entry) => entry.address.toLowerCase() === address);
            if (deployment?.interface.reportedVersion !== null) {
                return ok(cast(["abi-encode", "f(uint256)", deployment.interface.reportedVersion]));
            }
        }
        return undefined;
    };
}

async function batchScenario(callback, { baseUrl = true } = {}) {
    const scratch = mkdtempSync(resolve(tmpdir(), "fusion-drift-batch-"));
    const states = batchRegistry(scratch);
    try {
        let outcome;
        await withRpc(batchChainAt(1, states.get(1)), async (ethereumUrl) => {
            await withRpc(batchChainAt(8453, states.get(8453)), async (availableBaseUrl) => {
                outcome = await callback({
                    scratch,
                    states,
                    env: {
                        FUSION_DEPLOYMENTS_DIR: scratch,
                        ETHEREUM_PROVIDER_URL: ethereumUrl,
                        BASE_PROVIDER_URL: baseUrl ? availableBaseUrl : "",
                    },
                });
            });
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

test("the default batch discovers every verified deployment across both chains", async () => {
    const result = await batchScenario(({ env }) => invoke(["--json"], env));
    assert.equal(result.status, 0, result.stderr);
    const report = JSON.parse(result.stdout);
    assert.equal(report.kind, "deployment-drift-batch");
    assert.equal(report.status, "unchanged");
    assert.deepEqual(report.summary, { total: 4, unchanged: 4, drift: 0, unavailable: 0 });
    assert.deepEqual(
        report.results.map((entry) => entry.deploymentId).sort(),
        [...realManifest.deployments, ...baseManifest.deployments].map((entry) => entry.id).sort(),
    );
    assert.equal(report.results.filter((entry) => entry.coverage.version).length, 2);
    assert.equal(report.results.filter((entry) => !entry.coverage.version).length, 2);
    const priceFeed = report.results.find((entry) => entry.deploymentKind === "price-feed-factory");
    assert.equal(priceFeed.coverage.componentCodeHashes, 1);
    assert.doesNotMatch(result.stdout, /private-token|127\.0\.0\.1/);
});

test("one drifting entry fails the batch without skipping its siblings", async () => {
    const result = await batchScenario(({ env, states }) => {
        const wrapper = realManifest.deployments.find((entry) => entry.kind === "wrapped-vault-factory");
        states.get(1).code.set(wrapper.proxy.implementation.toLowerCase(), "0xdeadbeef");
        return invoke(["--json"], env);
    });
    assert.equal(result.status, 1, result.stderr);
    const report = JSON.parse(result.stdout);
    assert.deepEqual(report.summary, { total: 4, unchanged: 3, drift: 1, unavailable: 0 });
    const wrapper = report.results.find((entry) => entry.deploymentKind === "wrapped-vault-factory");
    assert.equal(wrapper.status, "drift");
    assert.deepEqual(wrapper.differences.map((difference) => difference.field), ["implementation.runtimeCodeHash"]);
});

test("a captured price-feed dependency code change is drift", async () => {
    const result = await batchScenario(({ env, states }) => {
        const middleware = realManifest.deployments.find((entry) => entry.kind === "price-feed-factory").dependencies[0];
        states.get(1).code.set(middleware.address.toLowerCase(), "0xdeadbeef");
        return invoke(["--json"], env);
    });
    assert.equal(result.status, 1, result.stderr);
    const report = JSON.parse(result.stdout);
    const priceFeed = report.results.find((entry) => entry.deploymentKind === "price-feed-factory");
    assert.equal(priceFeed.status, "drift");
    assert.deepEqual(priceFeed.differences.map((difference) => difference.field), [
        "component.price-oracle-middleware.runtimeCodeHash",
    ]);
});

test("one unavailable provider is exit 2 and the batch retains the other results", async () => {
    const outcome = await batchScenario(async ({ env, scratch }) => {
        const out = resolve(scratch, "batch-report.json");
        const result = await invoke(["--json", "--out", out], env);
        return { result, saved: JSON.parse(readFileSync(out, "utf8")) };
    }, { baseUrl: false });
    const { result, saved } = outcome;
    assert.equal(result.status, 2, result.stderr);
    const report = JSON.parse(result.stdout);
    assert.deepEqual(report.summary, { total: 4, unchanged: 3, drift: 0, unavailable: 1 });
    assert.deepEqual(saved.summary, report.summary, "the CI artifact must survive an unavailable comparison");
    const base = report.results.find((entry) => entry.chainId === 8453);
    assert.equal(base.status, "unavailable");
    assert.equal(base.error.code, "RPC_UNAVAILABLE");
});

test("a numeric block without a chain selection is refused as ambiguous", async () => {
    const result = await invoke(["--block", "25937526"]);
    assert.equal(result.status, 2);
    assert.match(result.stderr, /numeric block across multiple chains is ambiguous/);
});

test("a provider failure is a third outcome, not drift", async () => {
    const unset = await invoke(pilotSelection, { ETHEREUM_PROVIDER_URL: "" });
    assert.equal(unset.status, 2);
    assert.match(unset.stderr, /RPC_UNAVAILABLE/);

    const noBlock = await scenario(
        (request) => (request.method === "eth_chainId" ? ok("0x1") : undefined),
        pilotSelection,
    );
    assert.equal(noBlock.status, 2);
    assert.match(noBlock.stderr, /BLOCK_UNAVAILABLE/);

    const otherChain = await scenario(
        (request) => (request.method === "eth_chainId" ? ok("0xa4b1") : undefined),
        pilotSelection,
    );
    assert.equal(otherChain.status, 2);
    assert.match(otherChain.stderr, /CHAIN_MISMATCH/);
});

test("an unknown deployment cannot be compared", async () => {
    const result = await invoke(["--deployment", "ethereum-fusion-factory-unknown"]);
    assert.equal(result.status, 2);
    assert.match(result.stderr, /UNKNOWN_DEPLOYMENT/);
});

test("the scheduled workflow supplies both providers to the all-verified batch", () => {
    const workflow = readFileSync(resolve(repoRoot, ".github/workflows/pilot-drift.yml"), "utf8");
    assert.match(workflow, /ETHEREUM_PROVIDER_URL:.*secrets\.ETHEREUM_PROVIDER_URL/);
    assert.match(workflow, /BASE_PROVIDER_URL:.*secrets\.BASE_PROVIDER_URL/);
    assert.match(workflow, /npm run deployments:drift -- --block/);
    assert.doesNotMatch(workflow, /npm run deployments:drift.*--deployment/);
});

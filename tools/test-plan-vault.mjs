import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { createServer } from "node:http";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { test } from "node:test";

const repoRoot = resolve(import.meta.dirname, "..");
const planner = resolve(repoRoot, "tools/plan-vault.mjs");
const example = resolve(repoRoot, "config/vaults/example.json");
const implementation = "0xf19c1e9f6616f6056af1e322a86fdaaaaf0263f5";
const recipient = "0xF6a9bd8F6DC537675D499Ac1CA14f2c55d8b5569";
const block = "25937526";

function encode(signature, ...args) {
    const result = spawnSync("cast", ["abi-encode", signature, ...args], { cwd: repoRoot, encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
}

function selectorOf(signature) {
    const result = spawnSync("cast", ["sig", signature], { cwd: repoRoot, encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
}

const selectors = {
    version: selectorOf("getFusionFactoryVersion()"),
    client: selectorOf("getBusinessClientFeePackages(address)"),
    dao: selectorOf("getDaoFeePackages()"),
};

function invoke(args, env = {}) {
    return new Promise((done) => {
        const child = spawn(process.execPath, [planner, ...args], {
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
            response.setHeader("content-type", "application/json");
            response.end(JSON.stringify(handler(JSON.parse(body))));
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

/// A factory that answers exactly like the pilot did at the pinned block,
/// with the parts a scenario needs to change passed in.
function factory({ version = 8, isCustom = false, packages = [[5, 1000, recipient]] } = {}) {
    const packageList = `[${packages.map(([m, p, r]) => `(${m},${p},${r})`).join(",")}]`;
    return (request) => {
        if (request.method === "eth_chainId") return ok("0x1");
        if (request.method === "eth_getBlockByNumber") return ok({ hash: `0x${"ab".repeat(32)}` });
        if (request.method === "eth_getStorageAt") return ok(`0x${"0".repeat(24)}${implementation.slice(2)}`);
        if (request.method === "eth_call") {
            const data = request.params[0].data;
            if (data.startsWith(selectors.version)) return ok(encode("f(uint256)", String(version)));
            if (data.startsWith(selectors.client)) {
                return ok(encode("f((uint256,uint256,address)[],bool)", isCustom ? packageList : "[]", String(isCustom)));
            }
            if (data.startsWith(selectors.dao)) {
                return ok(encode("f((uint256,uint256,address)[])", isCustom ? "[]" : packageList));
            }
        }
        throw new Error(`unexpected request ${request.method}`);
    };
}

function withConfig(change) {
    const directory = mkdtempSync(resolve(tmpdir(), "fusion-plan-"));
    const path = resolve(directory, "config.json");
    const config = JSON.parse(readFileSync(example, "utf8"));
    change(config);
    writeFileSync(path, `${JSON.stringify(config, null, 4)}\n`);
    return { directory, path };
}

test("the plan's calldata decodes back to the configured inputs", async () => {
    await withRpc(factory(), async (url) => {
        const result = await invoke(["--config", example, "--block", block], { ETHEREUM_PROVIDER_URL: url });
        assert.equal(result.status, 0, result.stderr);
        const plan = JSON.parse(result.stdout);
        assert.equal(plan.transaction.to, "0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852");
        assert.equal(plan.transaction.value, "0");
        assert.equal(plan.transaction.from, "0x1111111111111111111111111111111111111111");
        assert.equal(plan.readBlock.number, Number(block));
        assert.match(plan.input.sha256, /^0x[0-9a-f]{64}$/);

        const decoded = spawnSync(
            "cast",
            ["decode-calldata", "clone(string,string,address,uint256,address,uint256)", plan.transaction.data],
            { cwd: repoRoot, encoding: "utf8" },
        );
        assert.equal(decoded.status, 0, decoded.stderr);
        const lines = decoded.stdout.trim().split("\n");
        assert.deepEqual(lines, [
            '"Example USDC Vault"',
            '"exUSDC"',
            "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
            "3600",
            "0x2222222222222222222222222222222222222222",
            "0",
        ]);
    });
});

test("no provider URL or token reaches the output", async () => {
    await withRpc(factory(), async (url) => {
        const result = await invoke(["--config", example, "--block", block], { ETHEREUM_PROVIDER_URL: url });
        assert.doesNotMatch(result.stdout + result.stderr, /private-token|127\.0\.0\.1/);
        assert.match(result.stdout, /ETHEREUM_PROVIDER_URL/);
    });
});

test("a factory version other than the manifest's stops planning", async () => {
    await withRpc(factory({ version: 9 }), async (url) => {
        const result = await invoke(["--config", example, "--block", block], { ETHEREUM_PROVIDER_URL: url });
        assert.equal(result.status, 1);
        assert.match(result.stderr, /UNSUPPORTED_FACTORY_VERSION.*version 8.*reports 9/);
    });
});

test("another implementation behind the proxy stops planning", async () => {
    const base = factory();
    const handler = (request) =>
        request.method === "eth_getStorageAt" ? ok(`0x${"0".repeat(24)}${"22".repeat(20)}`) : base(request);
    await withRpc(handler, async (url) => {
        const result = await invoke(["--config", example, "--block", block], { ETHEREUM_PROVIDER_URL: url });
        assert.equal(result.status, 1);
        assert.match(result.stderr, /IMPLEMENTATION_MISMATCH/);
    });
});

test("a fee package with different values stops planning", async () => {
    await withRpc(factory({ packages: [[7, 1000, recipient]] }), async (url) => {
        const result = await invoke(["--config", example, "--block", block], { ETHEREUM_PROVIDER_URL: url });
        assert.equal(result.status, 1);
        assert.match(result.stderr, /FEE_PACKAGE_MISMATCH.*managementFeeBps.*expects 5.*reports 7/);
    });
});

test("a fee package paying a different recipient stops planning", async () => {
    await withRpc(factory({ packages: [[5, 1000, "0x3333333333333333333333333333333333333333"]] }), async (url) => {
        const result = await invoke(["--config", example, "--block", block], { ETHEREUM_PROVIDER_URL: url });
        assert.equal(result.status, 1);
        assert.match(result.stderr, /FEE_PACKAGE_MISMATCH.*feeRecipient/);
    });
});

test("a caller on a business-client list is not planned against the global list", async () => {
    await withRpc(factory({ isCustom: true }), async (url) => {
        const result = await invoke(["--config", example, "--block", block], { ETHEREUM_PROVIDER_URL: url });
        assert.equal(result.status, 1);
        assert.match(result.stderr, /FEE_PACKAGE_MISMATCH.*dao-global.*business-client/);
    });
});

test("a package index outside the list stops planning", async () => {
    const { directory, path } = withConfig((config) => (config.fees.packageIndex = 3));
    try {
        await withRpc(factory(), async (url) => {
            const result = await invoke(["--config", path, "--block", block], { ETHEREUM_PROVIDER_URL: url });
            assert.equal(result.status, 1);
            assert.match(result.stderr, /FEE_PACKAGE_MISMATCH.*out of bounds/);
        });
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("an unverified manifest entry stops planning before any RPC call", async () => {
    const { directory, path } = withConfig((config) => (config.deploymentId = "ethereum-fusion-factory-unknown"));
    try {
        const result = await invoke(["--config", path, "--block", block]);
        assert.equal(result.status, 1);
        assert.match(result.stderr, /UNKNOWN_DEPLOYMENT/);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("a candidate manifest entry stops planning before any RPC call", async () => {
    const directory = mkdtempSync(resolve(tmpdir(), "fusion-registry-"));
    try {
        const manifest = JSON.parse(readFileSync(resolve(repoRoot, "deployments/1/factories.json"), "utf8"));
        manifest.deployments[0].status = "candidate";
        mkdirSync(resolve(directory, "1"), { recursive: true });
        writeFileSync(resolve(directory, "1/factories.json"), `${JSON.stringify(manifest, null, 4)}\n`);
        const result = await invoke(["--config", example, "--block", block], { FUSION_DEPLOYMENTS_DIR: directory });
        assert.equal(result.status, 1);
        assert.match(result.stderr, /UNVERIFIED_DEPLOYMENT.*"candidate"/);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("an invalid config stops planning before any RPC call", async () => {
    const { directory, path } = withConfig((config) => delete config.fees.expected.feeRecipient);
    try {
        const result = await invoke(["--config", path, "--block", block]);
        assert.equal(result.status, 1);
        assert.match(result.stderr, /INVALID_CONFIG.*feeRecipient/);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("a provider on another chain is a named error", async () => {
    const base = factory();
    const handler = (request) => (request.method === "eth_chainId" ? ok("0x2") : base(request));
    await withRpc(handler, async (url) => {
        const result = await invoke(["--config", example, "--block", block], { ETHEREUM_PROVIDER_URL: url });
        assert.equal(result.status, 1);
        assert.match(result.stderr, /CHAIN_MISMATCH/);
    });
});

test("a block the provider cannot serve is a named error", async () => {
    const base = factory();
    const handler = (request) =>
        request.method === "eth_getBlockByNumber" ? ok(null) : base(request);
    await withRpc(handler, async (url) => {
        const result = await invoke(["--config", example, "--block", block], { ETHEREUM_PROVIDER_URL: url });
        assert.equal(result.status, 1);
        assert.match(result.stderr, /HISTORICAL_STATE_UNAVAILABLE/);
    });
});

test("bad arguments exit with the input error code", async () => {
    const missing = await invoke(["--config", example]);
    assert.equal(missing.status, 2);
    assert.match(missing.stderr, /INVALID_ARGUMENT: missing --block/);

    const badBlock = await invoke(["--config", example, "--block", "latest"]);
    assert.equal(badBlock.status, 2);
    assert.match(badBlock.stderr, /INVALID_ARGUMENT/);
});

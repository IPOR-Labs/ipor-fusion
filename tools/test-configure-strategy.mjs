import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { parse as parseEnv } from "dotenv";
import { test } from "node:test";
import { startFork } from "./lib/fork.mjs";
import { rpc } from "./lib/chain.mjs";

const repoRoot = resolve(import.meta.dirname, "..");
const configurator = resolve(repoRoot, "tools/configure-strategy.mjs");
const strategy = resolve(repoRoot, "config/strategies/erc4626-usdc.json");
const factory = "0xcd05909C4A1F8E501e4ED554cEF4Ed5E48D9b852";
const usdc = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const sdai = "0x83F20F44975D03b1b09e64809B757c47f942BEeA";
const caller = "0x1111111111111111111111111111111111111111";
const owner = "0x2222222222222222222222222222222222222222";
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

function cast(args) {
    const result = spawnSync("cast", args, { cwd: repoRoot, encoding: "utf8" });
    assert.equal(result.status, 0, `cast ${args[0]}: ${result.stderr}`);
    return result.stdout.trim();
}

function run(args) {
    return new Promise((done) => {
        const child = spawn(process.execPath, [configurator, ...args], { cwd: repoRoot });
        let stdout = "";
        let stderr = "";
        child.stdout.on("data", (chunk) => (stdout += chunk));
        child.stderr.on("data", (chunk) => (stderr += chunk));
        child.on("close", (status) => done({ status, stdout, stderr }));
    });
}

/// Creates a vault through the unchanged deployed factory on the fork and
/// returns its address, read from the factory's own creation event.
async function createVault(url) {
    for (const account of [caller, owner]) {
        await rpc(url, "anvil_impersonateAccount", [account]);
        await rpc(url, "anvil_setBalance", [account, "0xde0b6b3a7640000"]);
    }
    const data = cast([
        "calldata",
        "clone(string,string,address,uint256,address,uint256)",
        "Strategy Pilot Vault",
        "spUSDC",
        usdc,
        "3600",
        owner,
        "0",
    ]);
    const hash = (await rpc(url, "eth_sendTransaction", [{ from: caller, to: factory, data, value: "0x0" }])).result;
    let receipt = null;
    for (let attempt = 0; attempt < 40 && receipt === null; attempt += 1) {
        receipt = (await rpc(url, "eth_getTransactionReceipt", [hash])).result;
        if (receipt === null) await new Promise((wait) => setTimeout(wait, 100));
    }
    const topic = cast([
        "keccak",
        "FusionInstanceCreated(uint256,uint256,string,string,uint8,address,string,uint8,address,address,address,address)",
    ]);
    const log = receipt.logs.find((entry) => entry.address.toLowerCase() === factory.toLowerCase() && entry.topics[0] === topic);
    const decoded = JSON.parse(
        cast([
            "decode-event",
            "--sig",
            "FusionInstanceCreated(uint256,uint256,string,string,uint8,address,string,uint8,address,address,address,address)",
            log.data,
            "--json",
        ]),
    );
    return decoded[9];
}

function variant(change) {
    const directory = mkdtempSync(resolve(tmpdir(), "fusion-strategy-"));
    const path = resolve(directory, "strategy.json");
    const value = JSON.parse(readFileSync(strategy, "utf8"));
    change(value);
    writeFileSync(path, `${JSON.stringify(value, null, 4)}\n`);
    return { directory, path };
}

test("bad arguments exit with the input error code", async () => {
    const result = await run(["--config", strategy, "--vault", "0x1234"]);
    assert.equal(result.status, 2);
    assert.match(result.stderr, /INVALID_ARGUMENT/);
});

test("an unknown integration and a market disagreement are refused before any call", async () => {
    const unknown = variant((value) => (value.catalogId = "ethereum-something-else"));
    const mismatched = variant((value) => (value.market.id = 100002));
    try {
        const first = await run(["--config", unknown.path, "--vault", usdc, "--rpc-url", "http://127.0.0.1:1"]);
        assert.equal(first.status, 1);
        assert.match(first.stderr, /UNKNOWN_INTEGRATION/);

        const second = await run(["--config", mismatched.path, "--vault", usdc, "--rpc-url", "http://127.0.0.1:1"]);
        assert.equal(second.status, 1);
        assert.match(second.stderr, /MARKET_MISMATCH/);
    } finally {
        rmSync(unknown.directory, { recursive: true, force: true });
        rmSync(mismatched.directory, { recursive: true, force: true });
    }
});

test("the configured operators configure the vault, and wrong inputs are named errors", async (t) => {
    const url = provider();
    if (!url) return t.skip("ETHEREUM_PROVIDER_URL is not configured");

    const fork = await startFork({ url, blockNumber: block, chainId: 1 });
    try {
        const vault = await createVault(fork.url);

        // 1. a substrate that is not denominated in the vault's asset
        const wrongAsset = variant((value) => (value.market.substrates[0].address = sdai));
        try {
            const result = await run(["--config", wrongAsset.path, "--vault", vault, "--rpc-url", fork.url]);
            assert.equal(result.status, 1);
            assert.match(result.stderr, /SUBSTRATE_ASSET_MISMATCH/);
        } finally {
            rmSync(wrongAsset.directory, { recursive: true, force: true });
        }

        // 2. an owner that does not hold OWNER_ROLE on this vault
        const wrongOwner = variant((value) => (value.operators.owner = "0x4444444444444444444444444444444444444444"));
        try {
            const result = await run(["--config", wrongOwner.path, "--vault", vault, "--rpc-url", fork.url]);
            assert.equal(result.status, 1);
            assert.match(result.stderr, /MISSING_ROLE.*OWNER_ROLE/);
        } finally {
            rmSync(wrongOwner.directory, { recursive: true, force: true });
        }

        // 3. the real configuration
        const planned = await run(["--config", strategy, "--vault", vault, "--rpc-url", fork.url, "--dry-run", "--json"]);
        assert.equal(planned.status, 0, planned.stderr);
        const plan = JSON.parse(planned.stdout);
        assert.equal(plan.status, "planned");
        assert.equal(plan.verification, null);
        assert.ok(plan.steps.every((step) => step.actions.every((action) => action.sent === false)));

        const configured = await run(["--config", strategy, "--vault", vault, "--rpc-url", fork.url, "--json"]);
        assert.equal(configured.status, 0, configured.stderr);
        const report = JSON.parse(configured.stdout);
        assert.equal(report.status, "configured");
        assert.equal(report.verification.ok, true, JSON.stringify(report.verification.checks));
        assert.deepEqual(
            report.steps.map((step) => step.id),
            ["grant-roles", "register-fuses", "grant-substrates", "set-limits"],
        );

        // 4. the vault itself reports the configuration
        const fuses = cast(["call", "--rpc-url", fork.url, vault, "getFuses()(address[])"]).toLowerCase();
        assert.ok(fuses.includes("0x12fd0ee183c85940caedd4877f5d3fc637515870"));
        const substrates = cast([
            "call",
            "--rpc-url",
            fork.url,
            vault,
            "getMarketSubstrates(uint256)(bytes32[])",
            "100001",
        ]).toLowerCase();
        assert.ok(substrates.includes("beef01735c132ada46aa9aa4c54623caa92a64cb"));
        assert.equal(
            cast(["call", "--rpc-url", fork.url, vault, "getMarketLimit(uint256)(uint256)", "100001"]).split(" ")[0],
            "500000000000000000",
        );
    } finally {
        fork.stop();
    }
});

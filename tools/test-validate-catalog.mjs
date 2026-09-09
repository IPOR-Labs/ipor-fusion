import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { test } from "node:test";

const repoRoot = resolve(import.meta.dirname, "..");
const validator = resolve(repoRoot, "tools/validate-catalog.mjs");
const catalog = resolve(repoRoot, "catalog/fuses.json");

function run(path) {
    return spawnSync(process.execPath, [validator, path], { cwd: repoRoot, encoding: "utf8" });
}

function mutate(change) {
    const directory = mkdtempSync(resolve(tmpdir(), "fusion-catalog-"));
    const path = resolve(directory, "fuses.json");
    const value = JSON.parse(readFileSync(catalog, "utf8"));
    change(value);
    writeFileSync(path, `${JSON.stringify(value, null, 4)}\n`);
    return { directory, path };
}

test("the pilot entry is valid against the checkout", () => {
    const result = run(catalog);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /valid catalog: 1 integration\(s\) checked/);
});

for (const scenario of [
    {
        name: "a source path that no longer exists",
        change: (value) => (value.integrations[0].source.actionFuse = "contracts/fuses/erc4626/Gone.sol"),
        expected: /source\.actionFuse.*does not exist/,
    },
    {
        name: "a test path that no longer exists",
        change: (value) => (value.integrations[0].tests[0] = "test/fuses/erc4626/Gone.t.sol"),
        expected: /tests\[0\].*does not exist/,
    },
    {
        name: "a market id the source constant does not have",
        change: (value) => (value.integrations[0].market.id = 100002),
        expected: /market\.id.*ERC4626_0001 is 100_001/,
    },
    {
        name: "a market constant that is not declared",
        change: (value) => (value.integrations[0].market.constant = "ERC4626_9999"),
        expected: /market\.constant.*is not defined/,
    },
    {
        name: "a selector that does not match its signature",
        change: (value) => (value.integrations[0].interface.enter.selector = "0xdeadbeef"),
        expected: /interface\.enter\.selector.*hashes to 0x41b11ae7/,
    },
    {
        name: "a struct that the fuse does not declare",
        change: (value) => (value.integrations[0].interface.exit.struct = "Erc4626SupplyFuseNoSuchData"),
        expected: /interface\.exit\.struct.*is not declared/,
    },
    {
        name: "a documented field list that does not match the struct",
        change: (value) => value.integrations[0].interface.enter.fields.pop(),
        expected: /interface\.enter\.fields.*declares 3 field\(s\), the catalog documents 2/,
    },
    {
        name: "an observed deployment without a block",
        change: (value) => (value.integrations[0].deployments.actionFuse.observedAtBlock = null),
        expected: /deployments\.actionFuse.*requires observedAtBlock/,
    },
    {
        name: "an observed deployment on another market",
        change: (value) => (value.integrations[0].deployments.balanceFuse.observedMarketId = 100002),
        expected: /observed market 100002 is not this integration's market 100001/,
    },
    {
        name: "an unverified deployment presented with observation data",
        change: (value) => (value.integrations[0].deployments.actionFuse.status = "unverified"),
        expected: /status "unverified" must not carry observation data/,
    },
    {
        name: "an unverified deployment claiming to match the current source",
        change: (value) => {
            const contract = value.integrations[0].deployments.balanceFuse;
            contract.status = "unverified";
            contract.observedAtBlock = null;
            contract.runtimeCodeHash = null;
            contract.matchesCurrentSource = true;
        },
        expected: /cannot match the current source without having been observed/,
    },
    {
        name: "an unknown property",
        change: (value) => (value.integrations[0].readyToUse = true),
        expected: /unknown property "readyToUse"/,
    },
]) {
    test(`rejects ${scenario.name}`, () => {
        const { directory, path } = mutate(scenario.change);
        try {
            const result = run(path);
            assert.equal(result.status, 1, `expected rejection\n${result.stdout}`);
            assert.match(result.stderr, scenario.expected);
        } finally {
            rmSync(directory, { recursive: true, force: true });
        }
    });
}

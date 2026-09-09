import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { test } from "node:test";

const repoRoot = resolve(import.meta.dirname, "..");
const validator = resolve(repoRoot, "tools/validate-vault-config.mjs");
const example = resolve(repoRoot, "config/vaults/example.json");

function run(...args) {
    return spawnSync(process.execPath, [validator, ...args], { cwd: repoRoot, encoding: "utf8" });
}

function mutate(change) {
    const directory = mkdtempSync(resolve(tmpdir(), "fusion-vault-config-"));
    const path = resolve(directory, "config.json");
    const config = JSON.parse(readFileSync(example, "utf8"));
    change(config);
    writeFileSync(path, `${JSON.stringify(config, null, 4)}\n`);
    return { directory, path };
}

test("the shipped example is valid", () => {
    const result = run(example);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /valid vault creation configs: 1 checked/);
});

test("--json reports the same verdict machine-readably", () => {
    const result = run(example, "--json");
    assert.equal(result.status, 0, result.stderr);
    const report = JSON.parse(result.stdout);
    assert.equal(report.status, "ok");
    assert.equal(report.results[0].file, "config/vaults/example.json");
});

for (const scenario of [
    {
        name: "a redemption delay written as text instead of seconds",
        change: (config) => (config.vault.redemptionDelaySeconds = "1 hour"),
        expected: /redemptionDelaySeconds.*expected type integer, got string/,
    },
    {
        name: "a fractional second",
        change: (config) => (config.vault.redemptionDelaySeconds = 0.5),
        expected: /redemptionDelaySeconds.*expected type integer, got number/,
    },
    {
        name: "a management fee written as a percentage fraction",
        change: (config) => (config.fees.expected.managementFeeBps = 0.05),
        expected: /managementFeeBps.*expected type integer, got number/,
    },
    {
        name: "basis points above 100%",
        change: (config) => (config.fees.expected.performanceFeeBps = 10001),
        expected: /performanceFeeBps.*above the maximum 10000/,
    },
    {
        name: "an incomplete fee package",
        change: (config) => delete config.fees.expected.feeRecipient,
        expected: /fees\.expected.*missing required property "feeRecipient"/,
    },
    {
        name: "a fee package without an explicit recipient",
        change: (config) => (config.fees.expected.feeRecipient = "0x0000000000000000000000000000000000000000"),
        expected: /feeRecipient.*zero address is not a usable participant/,
    },
    {
        name: "a variant the deployment does not support",
        change: (config) => (config.variant = "supervised-clone"),
        expected: /UNSUPPORTED_VARIANT.*cloneSupervised/,
    },
    {
        name: "a variant that does not exist at all",
        change: (config) => (config.variant = "create2-clone"),
        expected: /variant.*is not one of/,
    },
    {
        name: "an unknown deployment id",
        change: (config) => (config.deploymentId = "ethereum-fusion-factory-deadbeef"),
        expected: /UNKNOWN_DEPLOYMENT/,
    },
    {
        name: "a chain with no manifest",
        change: (config) => (config.chainId = 999999),
        expected: /UNKNOWN_DEPLOYMENT.*no manifest for chain 999999/,
    },
    {
        name: "a missing owner",
        change: (config) => delete config.vault.owner,
        expected: /vault.*missing required property "owner"/,
    },
    {
        name: "a malformed caller address",
        change: (config) => (config.caller = "0x1111"),
        expected: /caller.*does not match/,
    },
    {
        name: "underlying decimals stated as a string",
        change: (config) => (config.vault.underlying.decimals = "6"),
        expected: /decimals.*expected type integer, got string/,
    },
    {
        name: "an unknown property",
        change: (config) => (config.feeRecipientOverride = "0x1111111111111111111111111111111111111111"),
        expected: /unknown property "feeRecipientOverride"/,
    },
]) {
    test(`rejects ${scenario.name}`, () => {
        const { directory, path } = mutate(scenario.change);
        try {
            const result = run(path);
            assert.equal(result.status, 1, `expected rejection, got ${result.status}\n${result.stdout}`);
            assert.match(result.stderr, scenario.expected);
        } finally {
            rmSync(directory, { recursive: true, force: true });
        }
    });
}

test("a deployment that is still a candidate is refused", () => {
    const directory = mkdtempSync(resolve(tmpdir(), "fusion-registry-"));
    try {
        const manifest = JSON.parse(readFileSync(resolve(repoRoot, "deployments/1/factories.json"), "utf8"));
        manifest.deployments[0].status = "candidate";
        mkdirSync(resolve(directory, "1"), { recursive: true });
        writeFileSync(resolve(directory, "1/factories.json"), `${JSON.stringify(manifest, null, 4)}\n`);
        const result = spawnSync(process.execPath, [validator, example], {
            cwd: repoRoot,
            env: { ...process.env, FUSION_DEPLOYMENTS_DIR: directory },
            encoding: "utf8",
        });
        assert.equal(result.status, 1);
        assert.match(result.stderr, /UNVERIFIED_DEPLOYMENT.*"candidate"/);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("an unreadable file exits with the input error code", () => {
    const result = run(resolve(repoRoot, "config/vaults/does-not-exist.json"));
    assert.equal(result.status, 2);
    assert.match(result.stderr, /CONFIG_UNREADABLE/);
});

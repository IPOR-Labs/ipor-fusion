import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { test } from "node:test";

const repoRoot = resolve(import.meta.dirname, "..");
const validator = resolve(repoRoot, "tools/validate-deployments.mjs");
const fixture = resolve(repoRoot, "test/fixtures/deployments/valid-candidate.json");

function run(path) {
    return spawnSync(process.execPath, [validator, path], {
        cwd: repoRoot,
        encoding: "utf8",
    });
}

function mutate(callback) {
    const directory = mkdtempSync(resolve(tmpdir(), "fusion-deployment-manifest-"));
    const path = resolve(directory, "manifest.json");
    const manifest = JSON.parse(readFileSync(fixture, "utf8"));
    callback(manifest);
    writeFileSync(path, `${JSON.stringify(manifest, null, 4)}\n`);
    return { directory, path };
}

test("the synthetic candidate is valid", () => {
    const result = run(fixture);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /valid deployment manifests/);
});

for (const example of [
    {
        name: "malformed address",
        change: (manifest) => (manifest.deployments[0].address = "0x1234"),
        expected: /address.*does not match/,
    },
    {
        name: "deployment chain mismatch",
        change: (manifest) => (manifest.deployments[0].chainId = 2),
        expected: /deployment chain 2 does not match manifest 1/,
    },
    {
        name: "missing ABI reference",
        change: (manifest) => delete manifest.deployments[0].interface.abiPath,
        expected: /missing required property "abiPath"/,
    },
    {
        name: "missing ABI file",
        change: (manifest) => (manifest.deployments[0].interface.abiPath = "abi/missing/factory.json"),
        expected: /ABI file does not exist/,
    },
    {
        name: "ABI hash mismatch",
        change: (manifest) => (manifest.deployments[0].interface.abiSha256 = "0".repeat(64)),
        expected: /hash does not match/,
    },
    {
        name: "verified without evidence",
        change: (manifest) => (manifest.deployments[0].status = "verified"),
        expected: /verified deployment requires blockNumber/,
    },
]) {
    test(`invalid manifest: ${example.name}`, () => {
        const { directory, path } = mutate(example.change);
        try {
            const result = run(path);
            assert.equal(result.status, 1);
            assert.match(result.stderr, example.expected);
        } finally {
            rmSync(directory, { recursive: true, force: true });
        }
    });
}

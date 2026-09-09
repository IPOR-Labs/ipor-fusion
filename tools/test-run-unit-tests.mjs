import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const runner = resolve(repoRoot, "tools/run-unit-tests.mjs");
const catalogPath = resolve(repoRoot, "config/test-suites.json");

function invoke(args = [], env = {}) {
    return spawnSync(process.execPath, [runner, ...args], {
        cwd: repoRoot,
        env: { ...process.env, ...env },
        encoding: "utf8",
    });
}

test("an empty RPC-free selection fails visibly", () => {
    const directory = mkdtempSync(resolve(tmpdir(), "fusion-unit-runner-"));
    try {
        const catalog = JSON.parse(readFileSync(catalogPath, "utf8"));
        catalog.suites = catalog.suites.filter((suite) => suite.fixture !== "local-deployment");
        const path = resolve(directory, "fork-only.json");
        writeFileSync(path, `${JSON.stringify(catalog, null, 4)}\n`);

        const result = invoke(["--catalog", path]);
        assert.equal(result.status, 1);
        assert.match(result.stderr, /no RPC-free local-deployment suites/);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("a Forge failure is returned to the caller", () => {
    const result = invoke([], { FORGE_BIN: "/bin/false" });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /profile factory_local failed \(Forge exit 1\)/);
    assert.doesNotMatch(result.stdout, /test:unit: PASS/);
});

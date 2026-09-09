import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, resolve } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const runner = resolve(repoRoot, "tools/run-fork-tests.mjs");
const catalogPath = resolve(repoRoot, "config/test-suites.json");

function invoke(args, env = {}) {
    const childEnv = { ...process.env, FUSION_ENV_FILE: "/dev/null", ...env };
    if (env.ETHEREUM_PROVIDER_URL === null) delete childEnv.ETHEREUM_PROVIDER_URL;
    return spawnSync(process.execPath, [runner, ...args], {
        cwd: repoRoot,
        env: childEnv,
        encoding: "utf8",
    });
}

const validArgs = ["--chain", "1", "--suite", "factory", "--block", "23831825"];

test("missing RPC is a named failure and does not print a URL", () => {
    const result = invoke(validArgs, { ETHEREUM_PROVIDER_URL: null });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /RPC_UNAVAILABLE: ETHEREUM_PROVIDER_URL is not set/);
    assert.doesNotMatch(result.stderr, /https?:\/\//);
});

test("unsupported chain and suite are distinct failures", () => {
    const chain = invoke(["--chain", "999", "--suite", "factory", "--block", "1"]);
    assert.equal(chain.status, 1);
    assert.match(chain.stderr, /UNSUPPORTED_CHAIN/);

    const suite = invoke(["--chain", "1", "--suite", "unknown", "--block", "1"]);
    assert.equal(suite.status, 1);
    assert.match(suite.stderr, /UNSUPPORTED_SUITE/);
});

test("a supported chain and group with no intersecting fork suite fails as an empty selection", () => {
    const directory = mkdtempSync(resolve(tmpdir(), "fusion-fork-empty-"));
    try {
        const catalog = JSON.parse(readFileSync(catalogPath, "utf8"));
        for (const suite of catalog.suites) {
            if (suite.fixture !== "local-deployment") suite.group = "other";
        }
        const path = resolve(directory, "empty-selection.json");
        writeFileSync(path, `${JSON.stringify(catalog, null, 4)}\n`);

        const result = invoke([...validArgs, "--catalog", path]);
        assert.equal(result.status, 1);
        assert.match(result.stderr, /EMPTY_SELECTION/);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("the requested block and selected paths reach Forge", () => {
    const directory = mkdtempSync(resolve(tmpdir(), "fusion-fork-runner-"));
    try {
        const fakeForge = resolve(directory, "forge");
        const capture = resolve(directory, "capture.txt");
        writeFileSync(fakeForge, '#!/bin/sh\nprintf "%s\\n%s\\n" "$FUSION_FORK_BLOCK" "$*" > "$FUSION_CAPTURE_FILE"\n');
        chmodSync(fakeForge, 0o755);

        const result = invoke(validArgs, {
            ETHEREUM_PROVIDER_URL: "http://127.0.0.1:1",
            FORGE_BIN: fakeForge,
            FUSION_CAPTURE_FILE: capture,
        });
        assert.equal(result.status, 0, result.stderr);
        const captured = readFileSync(capture, "utf8");
        assert.match(captured, /^23831825$/m);
        assert.match(captured, /FusionFactoryDaoFeePackagesForkTest\.t\.sol/);
        assert.match(captured, /FusionFactoryBusinessClientFeePackagesForkTest\.t\.sol/);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("a Forge failure is propagated", () => {
    const result = invoke(validArgs, {
        ETHEREUM_PROVIDER_URL: "http://127.0.0.1:1",
        FORGE_BIN: "/bin/false",
    });
    assert.equal(result.status, 1);
    assert.match(result.stderr, /FORGE_FAILED: Forge exited with 1/);
    assert.doesNotMatch(result.stdout, /test:fork: PASS/);
});

test("both fork fixtures consume and assert FUSION_FORK_BLOCK", () => {
    for (const path of [
        "test/factory/FusionFactoryDaoFeePackagesForkTest.t.sol",
        "test/factory/FusionFactoryBusinessClientFeePackagesForkTest.t.sol",
    ]) {
        const source = readFileSync(resolve(repoRoot, path), "utf8");
        assert.match(source, /vm\.envOr\("FUSION_FORK_BLOCK", FORK_BLOCK\)/);
        assert.match(source, /function testForkRunnerUsesRequestedBlock\(\)/);
    }
});

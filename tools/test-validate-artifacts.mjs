import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { test } from "node:test";

const repoRoot = resolve(import.meta.dirname, "..");
const validator = resolve(repoRoot, "tools/validate-artifacts.mjs");
const fixtures = {
    plan: resolve(repoRoot, "test/fixtures/artifacts/valid-vault-creation-plan.json"),
    simulation: resolve(repoRoot, "test/fixtures/artifacts/valid-vault-creation-simulation.json"),
    preflight: resolve(repoRoot, "test/fixtures/artifacts/valid-vault-creation-preflight.json"),
};

function run(...args) {
    return spawnSync(process.execPath, [validator, ...args], { cwd: repoRoot, encoding: "utf8" });
}

function runTool(tool, args) {
    return spawnSync(process.execPath, [resolve(repoRoot, tool), ...args], {
        cwd: repoRoot,
        encoding: "utf8",
        env: { ...process.env, FUSION_ENV_FILE: "/dev/null", ETHEREUM_PROVIDER_URL: "" },
    });
}

function mutate(source, change) {
    const directory = mkdtempSync(resolve(tmpdir(), "fusion-artifact-"));
    const path = resolve(directory, "artifact.json");
    const artifact = JSON.parse(readFileSync(source, "utf8"));
    change(artifact);
    writeFileSync(path, `${JSON.stringify(artifact, null, 4)}\n`);
    return { directory, path };
}

test("the three shipped artifact fixtures are valid", () => {
    const result = run(fixtures.plan, fixtures.simulation, fixtures.preflight);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /valid vault artifacts: 3 checked/);
});

test("--json reports the artifact kind and verdict", () => {
    const result = run(fixtures.plan, "--json");
    assert.equal(result.status, 0, result.stderr);
    const report = JSON.parse(result.stdout);
    assert.equal(report.status, "ok");
    assert.equal(report.results[0].kind, "vault-creation");
    assert.equal(report.results[0].valid, true);
});

for (const scenario of [
    {
        name: "a plan missing its calldata",
        source: fixtures.plan,
        change: (artifact) => delete artifact.transaction.data,
        expected: /transaction.*missing required property "data"/,
    },
    {
        name: "an undeclared plan override",
        source: fixtures.plan,
        change: (artifact) => (artifact.transaction.gasLimit = 1),
        expected: /transaction.*unknown property "gasLimit"/,
    },
    {
        name: "a non-zero value on the non-payable creation call",
        source: fixtures.plan,
        change: (artifact) => (artifact.transaction.value = "1"),
        expected: /transaction\.value.*is not one of.*"0"/,
    },
    {
        name: "a malformed simulation block hash",
        source: fixtures.simulation,
        change: (artifact) => (artifact.fork.blockHash = "0x1234"),
        expected: /fork\.blockHash.*does not match/,
    },
    {
        name: "a preflight check with a textual verdict",
        source: fixtures.preflight,
        change: (artifact) => (artifact.checks[0].ok = "yes"),
        expected: /checks\[0\]\.ok.*expected type boolean, got string/,
    },
    {
        name: "an unsupported artifact kind",
        source: fixtures.plan,
        change: (artifact) => (artifact.kind = "vault-creation-receipt"),
        expected: /unsupported artifact kind/,
    },
]) {
    test(`rejects ${scenario.name}`, () => {
        const { directory, path } = mutate(scenario.source, scenario.change);
        try {
            const result = run(path);
            assert.equal(result.status, 1, result.stdout);
            assert.match(result.stderr, scenario.expected);
        } finally {
            rmSync(directory, { recursive: true, force: true });
        }
    });
}

test("missing and unreadable inputs use the input error exit code", () => {
    const missingArgument = run();
    assert.equal(missingArgument.status, 2);
    assert.match(missingArgument.stderr, /INVALID_ARGUMENT/);

    const unreadable = run(resolve(repoRoot, "does-not-exist.json"));
    assert.equal(unreadable.status, 2);
    assert.match(unreadable.stderr, /ARTIFACT_UNREADABLE/);
});

test("every plan consumer rejects a malformed plan before RPC", () => {
    const { directory, path } = mutate(fixtures.plan, (artifact) => delete artifact.transaction.data);
    const scope = resolve(repoRoot, "config/execution/scope.example.json");
    try {
        const commands = [
            ["tools/simulate-vault.mjs", ["--plan", path]],
            ["tools/preflight-plan.mjs", ["--plan", path]],
            ["tools/execution-journal.mjs", ["record", "--plan", path]],
            [
                "tools/execute-plan.mjs",
                ["--plan", path, "--scope", scope, "--fork-unlocked", "--rpc-url", "http://127.0.0.1:1"],
            ],
            ["tools/export-safe-plan.mjs", ["--plan", path]],
        ];
        for (const [tool, args] of commands) {
            const result = runTool(tool, args);
            assert.equal(result.status, 1, `${tool}\n${result.stdout}\n${result.stderr}`);
            assert.match(result.stderr, /INVALID_PLAN.*missing required property "data"/, tool);
            assert.doesNotMatch(result.stderr, /RPC_UNAVAILABLE|ECONNREFUSED/, tool);
        }
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

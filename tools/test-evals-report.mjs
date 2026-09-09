import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { test } from "node:test";

const repoRoot = resolve(import.meta.dirname, "..");
const reporter = resolve(repoRoot, "tools/evals-report.mjs");

function run(...args) {
    return spawnSync(process.execPath, [reporter, ...args], { cwd: repoRoot, encoding: "utf8" });
}

const metrics = (overrides = {}) => ({
    timeToFirstRelevantTestMinutes: 12,
    humanInterventions: 1,
    costTokens: 40000,
    redundantReads: 3,
    evidenceQuality: 2,
    ...overrides,
});

function runRecord(overrides = {}) {
    return {
        schemaVersion: 1,
        runId: "run-1",
        date: "2026-09-01",
        label: "baseline",
        conditions: {
            commit: "6e1fd02",
            model: "some-model",
            toolsAvailable: ["bash", "foundry"],
            workBudgetMinutes: 60,
            networkAccess: "rpc-only",
            memoryMode: "none",
            repeats: 3,
        },
        fixtures: { pilot_network: "ethereum" },
        results: ["E1", "E2", "E3", "E4", "E5", "E6", "E7", "E8"].map((task) => ({
            task,
            score: "pass",
            blockedBy: null,
            hardFail: null,
            notes: null,
            metrics: metrics(),
        })),
        ...overrides,
    };
}

function withRuns(records) {
    const directory = mkdtempSync(resolve(tmpdir(), "fusion-evals-"));
    const runs = resolve(directory, "runs");
    mkdirSync(runs);
    for (const record of records) writeFileSync(resolve(runs, `${record.runId}.json`), `${JSON.stringify(record, null, 4)}\n`);
    return { directory, runs };
}

test("an empty or missing directory is not an error", () => {
    const missing = run("--runs", resolve(repoRoot, "evals/agent-readiness/does-not-exist"));
    assert.equal(missing.status, 0);
    assert.match(missing.stdout, /no runs recorded yet/);

    const { directory, runs } = withRuns([]);
    try {
        const empty = run("--runs", runs);
        assert.equal(empty.status, 0);
        assert.match(empty.stdout, /no runs recorded yet/);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("a run reports success, interventions, time and cost", () => {
    const record = runRecord();
    record.results[0] = { ...record.results[0], score: "fail" };
    record.results[1] = { ...record.results[1], score: "blocked", blockedBy: "no archive RPC provider" };
    const { directory, runs } = withRuns([record]);
    try {
        const result = run("--runs", runs, "--json");
        assert.equal(result.status, 0, result.stderr);
        const report = JSON.parse(result.stdout);
        const summary = report.runs[0];
        assert.equal(summary.tasks, 8);
        assert.equal(summary.passed, 6);
        assert.equal(summary.failed, 1);
        assert.equal(summary.blocked, 1);
        // Blocked is a reported limitation, so it leaves the denominator: 6 of 7.
        assert.equal(summary.successRate, 0.857);
        assert.equal(summary.humanInterventions, 8);
        assert.equal(summary.costTokens, 320000);
        assert.equal(summary.medianTimeToFirstRelevantTestMinutes, 12);
        assert.equal(summary.averageEvidenceQuality, 2);
        assert.equal(report.targets.success_rate, 0.8);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("a hard fail is surfaced, not averaged away", () => {
    const record = runRecord();
    record.results[3] = { ...record.results[3], score: "fail", hardFail: "used an address it never read" };
    const { directory, runs } = withRuns([record]);
    try {
        const result = run("--runs", runs);
        assert.equal(result.status, 0, result.stderr);
        assert.match(result.stdout, /HARD FAIL E4: used an address it never read/);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("runs under different conditions are reported as not comparable", () => {
    const baseline = runRecord();
    const candidate = runRecord({
        runId: "run-2",
        date: "2026-09-08",
        label: "after the readiness work",
        conditions: { ...runRecord().conditions, commit: "562fea3", model: "another-model" },
    });
    const { directory, runs } = withRuns([baseline, candidate]);
    try {
        const result = run("--runs", runs, "--compare", "run-2", "--json");
        assert.equal(result.status, 0, result.stderr);
        const { comparison } = JSON.parse(result.stdout);
        assert.equal(comparison.comparable, false);
        assert.deepEqual(comparison.conditionsChanged.sort(), ["commit", "model"]);

        const text = run("--runs", runs, "--compare", "run-2");
        assert.match(text.stdout, /NOT COMPARABLE/);
        assert.match(text.stdout, /difference in conditions, not in the repository/);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("two runs that differ only by commit are compared", () => {
    const baseline = runRecord();
    const candidate = runRecord({
        runId: "run-2",
        date: "2026-09-08",
        conditions: { ...runRecord().conditions, commit: "562fea3" },
    });
    candidate.results = candidate.results.map((result) => ({
        ...result,
        metrics: metrics({ humanInterventions: 0, costTokens: 30000 }),
    }));
    const { directory, runs } = withRuns([baseline, candidate]);
    try {
        const result = run("--runs", runs, "--compare", "run-2", "--json");
        const { comparison } = JSON.parse(result.stdout);
        assert.equal(comparison.comparable, true);
        assert.equal(comparison.deltas.humanInterventions, -8);
        assert.equal(comparison.deltas.costTokens, -80000);
        assert.equal(comparison.deltas.successRate, 0);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

for (const scenario of [
    {
        name: "a run that is missing a task",
        change: (record) => record.results.pop(),
        expected: /no result for E8/,
    },
    {
        name: "a blocked task that does not name what was missing",
        change: (record) => (record.results[0] = { ...record.results[0], score: "blocked", blockedBy: null }),
        expected: /blocked without naming the missing prerequisite/,
    },
    {
        name: "a task that is not part of the suite",
        change: (record) => (record.results[0] = { ...record.results[0], task: "E9" }),
        expected: /does not match|E9 is not a task/,
    },
    {
        name: "a memory mode the schema does not allow",
        change: (record) => (record.conditions.memoryMode = "whatever"),
        expected: /memoryMode.*not one of/,
    },
    {
        name: "an evidence score outside its range",
        change: (record) => (record.results[2].metrics.evidenceQuality = 7),
        expected: /evidenceQuality.*above the maximum 3/,
    },
]) {
    test(`rejects ${scenario.name}`, () => {
        const record = runRecord();
        scenario.change(record);
        const { directory, runs } = withRuns([record]);
        try {
            const result = run("--runs", runs);
            assert.equal(result.status, 1, `expected rejection\n${result.stdout}`);
            assert.match(result.stderr, scenario.expected);
        } finally {
            rmSync(directory, { recursive: true, force: true });
        }
    });
}

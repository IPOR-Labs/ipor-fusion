#!/usr/bin/env node
// Validates agent-readiness run records and reports what they measured.
//
// Usage:
//   node tools/evals-report.mjs [--runs <dir>] [--compare <runId>] [--json]
//
// Exit codes: 0 reported, 1 a record is invalid or a comparison is impossible,
// 2 nothing to read.
//
// A run is only comparable with another when their conditions match. When they
// do not, the differing conditions are reported and the comparison is refused —
// a better score after a model or memory change says nothing about the
// repository.

import { existsSync, readFileSync, readdirSync } from "node:fs";
import { relative, resolve } from "node:path";
import { validateSchema } from "./lib/json-schema.mjs";

const repoRoot = resolve(import.meta.dirname, "..");
const schemaPath = resolve(repoRoot, "evals/agent-readiness/results.schema.json");
const tasksPath = resolve(repoRoot, "evals/agent-readiness/tasks.json");

function die(code, message, exitCode = 1) {
    console.error(`evals:report: ${code}: ${message}`);
    process.exit(exitCode);
}

function parseArgs(argv) {
    const values = {};
    const rest = [];
    for (const arg of argv) {
        if (arg === "--json") values[arg] = true;
        else rest.push(arg);
    }
    for (let index = 0; index < rest.length; index += 2) {
        if (!rest[index + 1] || !["--runs", "--compare"].includes(rest[index])) {
            die("INVALID_ARGUMENT", "expected [--runs <dir>] [--compare <runId>] [--json]", 2);
        }
        values[rest[index]] = rest[index + 1];
    }
    return {
        runsDir: resolve(values["--runs"] ?? resolve(repoRoot, "evals/agent-readiness/runs")),
        compare: values["--compare"],
        asJson: values["--json"] === true,
    };
}

const input = parseArgs(process.argv.slice(2));
const readJson = (path, code) => {
    try {
        return JSON.parse(readFileSync(path, "utf8"));
    } catch (error) {
        die(code, `${path}: ${error.message}`, 2);
    }
};

const schema = readJson(schemaPath, "SCHEMA_UNREADABLE");
const suite = readJson(tasksPath, "TASKS_UNREADABLE");
const expectedTasks = suite.tasks.map((task) => task.id);

if (!existsSync(input.runsDir)) {
    console.log(`evals:report: no runs recorded yet (${relative(repoRoot, input.runsDir)} does not exist)`);
    console.log("  the protocol is in evals/agent-readiness/baseline.md; a run is recorded as one JSON file per run");
    process.exit(0);
}

const files = readdirSync(input.runsDir)
    .filter((name) => name.endsWith(".json"))
    .map((name) => resolve(input.runsDir, name));

if (files.length === 0) {
    console.log(`evals:report: no runs recorded yet (${relative(repoRoot, input.runsDir)} is empty)`);
    process.exit(0);
}

const runs = [];
const errors = [];
for (const file of files) {
    const run = readJson(file, "RUN_UNREADABLE");
    for (const error of validateSchema(run, schema)) errors.push(`${relative(repoRoot, file)} ${error}`);

    const seen = new Set();
    for (const result of run.results ?? []) {
        if (seen.has(result.task)) errors.push(`${relative(repoRoot, file)}: duplicate result for ${result.task}`);
        seen.add(result.task);
        if (!expectedTasks.includes(result.task)) {
            errors.push(`${relative(repoRoot, file)}: ${result.task} is not a task of this suite`);
        }
        if (result.score === "blocked" && !result.blockedBy) {
            errors.push(`${relative(repoRoot, file)}: ${result.task} is blocked without naming the missing prerequisite`);
        }
    }
    const missing = expectedTasks.filter((task) => !seen.has(task));
    if (missing.length > 0) errors.push(`${relative(repoRoot, file)}: no result for ${missing.join(", ")}`);
    runs.push(run);
}

if (errors.length > 0) {
    console.error("invalid run records:");
    for (const error of errors) console.error(`  ${error}`);
    process.exit(1);
}

function summarize(run) {
    const counted = run.results.filter((result) => result.score !== "blocked");
    const passed = run.results.filter((result) => result.score === "pass").length;
    const sum = (pick) => run.results.reduce((total, result) => total + (pick(result) ?? 0), 0);
    const times = run.results
        .map((result) => result.metrics.timeToFirstRelevantTestMinutes)
        .filter((value) => typeof value === "number");
    return {
        runId: run.runId,
        date: run.date,
        label: run.label ?? null,
        conditions: run.conditions,
        tasks: run.results.length,
        // Blocked tasks are a report of a missing prerequisite, so they are kept
        // out of the success rate rather than counted as failures.
        passed,
        failed: run.results.filter((result) => result.score === "fail").length,
        blocked: run.results.filter((result) => result.score === "blocked").length,
        successRate: counted.length === 0 ? null : Number((passed / counted.length).toFixed(3)),
        hardFails: run.results.filter((result) => result.hardFail).map((result) => `${result.task}: ${result.hardFail}`),
        humanInterventions: sum((result) => result.metrics.humanInterventions),
        costTokens: sum((result) => result.metrics.costTokens),
        medianTimeToFirstRelevantTestMinutes:
            times.length === 0 ? null : times.sort((left, right) => left - right)[Math.floor(times.length / 2)],
        averageEvidenceQuality:
            run.results.length === 0
                ? null
                : Number((sum((result) => result.metrics.evidenceQuality) / run.results.length).toFixed(2)),
    };
}

const summaries = runs.map(summarize).sort((left, right) => left.date.localeCompare(right.date));
let comparison = null;

if (input.compare) {
    const later = summaries.find((summary) => summary.runId === input.compare);
    if (!later) die("UNKNOWN_RUN", `no run with id "${input.compare}"`);
    const earlier = summaries.filter((summary) => summary.runId !== input.compare).at(0);
    if (!earlier) die("NO_BASELINE", "there is no other run to compare with");

    const changed = Object.entries(later.conditions)
        .filter(([key, value]) => JSON.stringify(value) !== JSON.stringify(earlier.conditions[key]))
        .map(([key]) => key);
    comparison = {
        baseline: earlier.runId,
        candidate: later.runId,
        conditionsChanged: changed,
        comparable: changed.filter((key) => key !== "commit").length === 0,
        deltas: {
            successRate:
                later.successRate === null || earlier.successRate === null
                    ? null
                    : Number((later.successRate - earlier.successRate).toFixed(3)),
            humanInterventions: later.humanInterventions - earlier.humanInterventions,
            costTokens: later.costTokens - earlier.costTokens,
            blocked: later.blocked - earlier.blocked,
        },
    };
}

const report = {
    schemaVersion: 1,
    suite: suite.suite,
    targets: suite.scoring.targets,
    runs: summaries,
    comparison,
};

if (input.asJson) {
    process.stdout.write(`${JSON.stringify(report, null, 4)}\n`);
} else {
    console.log(`evals:report: ${summaries.length} run(s), target success rate ${suite.scoring.targets.success_rate}`);
    for (const summary of summaries) {
        console.log(
            `  ${summary.runId} ${summary.date} ${summary.conditions.model} memory=${summary.conditions.memoryMode} commit=${summary.conditions.commit}`,
        );
        console.log(
            `    pass ${summary.passed}/${summary.tasks}  fail ${summary.failed}  blocked ${summary.blocked}  success rate ${summary.successRate ?? "n/a"}`,
        );
        console.log(
            `    interventions ${summary.humanInterventions}  tokens ${summary.costTokens}  median time-to-first-test ${summary.medianTimeToFirstRelevantTestMinutes ?? "n/a"} min  evidence ${summary.averageEvidenceQuality}`,
        );
        for (const hardFail of summary.hardFails) console.log(`    HARD FAIL ${hardFail}`);
    }
    if (comparison) {
        console.log(`  comparison ${comparison.baseline} -> ${comparison.candidate}`);
        if (!comparison.comparable) {
            console.log(`    NOT COMPARABLE: conditions changed (${comparison.conditionsChanged.join(", ")})`);
            console.log("    a difference in score here is a difference in conditions, not in the repository");
        } else {
            console.log(
                `    success rate ${comparison.deltas.successRate >= 0 ? "+" : ""}${comparison.deltas.successRate}  interventions ${comparison.deltas.humanInterventions >= 0 ? "+" : ""}${comparison.deltas.humanInterventions}  tokens ${comparison.deltas.costTokens >= 0 ? "+" : ""}${comparison.deltas.costTokens}`,
            );
        }
    }
}
process.exit(0);

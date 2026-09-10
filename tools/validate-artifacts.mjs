#!/usr/bin/env node
// Validates plan, simulation and preflight JSON artifacts against the schema
// selected by each artifact's `kind` field.
//
// Usage:
//   node tools/validate-artifacts.mjs <artifact.json> [...] [--json]
//
// Exit codes: 0 valid, 1 invalid, 2 missing or unreadable input.

import { readFileSync } from "node:fs";
import { relative, resolve } from "node:path";
import { validateArtifact } from "./lib/artifact-schema.mjs";

const repoRoot = resolve(import.meta.dirname, "..");
const args = process.argv.slice(2);
const asJson = args.includes("--json");
const inputs = args.filter((arg) => arg !== "--json").map((path) => resolve(path));

if (inputs.length === 0) {
    console.error("validate:artifacts: INVALID_ARGUMENT: expected at least one artifact file");
    process.exit(2);
}

const results = [];
for (const file of inputs) {
    let artifact;
    try {
        artifact = JSON.parse(readFileSync(file, "utf8"));
    } catch (error) {
        console.error(`validate:artifacts: ARTIFACT_UNREADABLE: ${file}: ${error.message}`);
        process.exit(2);
    }
    const findings = validateArtifact(artifact);
    results.push({ file: relative(repoRoot, file), kind: artifact?.kind ?? null, valid: findings.length === 0, findings });
}

const invalid = results.filter((result) => !result.valid);
if (asJson) {
    process.stdout.write(
        `${JSON.stringify({ schemaVersion: 1, status: invalid.length === 0 ? "ok" : "invalid", results }, null, 4)}\n`,
    );
} else if (invalid.length === 0) {
    console.log(`valid vault artifacts: ${results.length} checked`);
} else {
    console.error("invalid vault artifacts:");
    for (const result of invalid) {
        for (const finding of result.findings) console.error(`  ${result.file} ${finding}`);
    }
}

process.exit(invalid.length === 0 ? 0 : 1);

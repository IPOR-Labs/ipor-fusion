#!/usr/bin/env node
// Validates a vault creation input against config/vaults/vault-creation.schema.json
// and against the deployment manifest it names.
//
// Usage:
//   node tools/validate-vault-config.mjs [config.json ...] [--json]
//
// Exit codes: 0 valid, 1 invalid, 2 could not read an input file.
//
// This command only checks the input. It reads no RPC, prepares no calldata and
// resolves nothing that depends on chain state: whether the caller really has a
// business-client package, or what the selected package holds right now, is an
// on-chain question answered when the operation is planned.

import { relative, resolve } from "node:path";
import { checkVaultConfig, defaultConfigPath, InputError, readJsonOrThrow, repoRoot } from "./lib/vault-config.mjs";

const args = process.argv.slice(2);
const asJson = args.includes("--json");
const inputs = args.filter((arg) => arg !== "--json").map((path) => resolve(path));
if (inputs.length === 0) inputs.push(defaultConfigPath);

const results = [];
try {
    for (const file of inputs) {
        const config = readJsonOrThrow(file, "CONFIG_UNREADABLE");
        const { findings } = checkVaultConfig(config);
        results.push({ file: relative(repoRoot, file), valid: findings.length === 0, findings });
    }
} catch (error) {
    if (!(error instanceof InputError)) throw error;
    console.error(`validate:vault-config: ${error.code}: ${error.message}`);
    process.exit(2);
}

const invalid = results.filter((result) => !result.valid);

if (asJson) {
    console.log(JSON.stringify({ schemaVersion: 1, status: invalid.length === 0 ? "ok" : "invalid", results }, null, 2));
} else if (invalid.length === 0) {
    console.log(`valid vault creation configs: ${results.length} checked`);
} else {
    console.error("invalid vault creation configs:");
    for (const result of invalid) {
        for (const finding of result.findings) {
            console.error(`  ${result.file} ${finding.where}: ${finding.code}: ${finding.message}`);
        }
    }
}

process.exit(invalid.length === 0 ? 0 : 1);

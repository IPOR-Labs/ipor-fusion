#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const defaultCatalog = resolve(repoRoot, "config/test-suites.json");
const validator = resolve(repoRoot, "tools/validate-test-suites.mjs");

function fail(message, code = 1) {
    console.error(`test:unit: ${message}`);
    process.exit(code);
}

function parseArgs(argv) {
    let catalog = defaultCatalog;
    for (let index = 0; index < argv.length; index += 1) {
        if (argv[index] === "--catalog" && argv[index + 1]) {
            catalog = resolve(argv[index + 1]);
            index += 1;
        } else {
            fail(`unknown or incomplete argument ${JSON.stringify(argv[index])}`, 2);
        }
    }
    return { catalog };
}

function run(command, args, options = {}) {
    const result = spawnSync(command, args, {
        cwd: repoRoot,
        env: options.env ?? process.env,
        encoding: "utf8",
        stdio: options.stdio ?? "inherit",
    });
    if (result.error) fail(`cannot start ${command}: ${result.error.message}`, 2);
    return result.status ?? 1;
}

const { catalog } = parseArgs(process.argv.slice(2));

const validationStatus = run(process.execPath, [validator, catalog]);
if (validationStatus !== 0) fail(`catalog validation failed (exit ${validationStatus})`, validationStatus);

let data;
try {
    data = JSON.parse(readFileSync(catalog, "utf8"));
} catch (error) {
    fail(`cannot read ${catalog}: ${error.message}`, 2);
}

const suites = data.suites.filter((suite) => suite.fixture === "local-deployment");
if (suites.length === 0) fail(`catalog contains no RPC-free local-deployment suites`);

const childEnv = { ...process.env };
for (const suite of data.suites) {
    if (typeof suite.rpc === "string") childEnv[suite.rpc] = "http://127.0.0.1:1";
}

const forge = process.env.FORGE_BIN || "forge";
console.log(`test:unit: running ${suites.length} RPC-free suite(s)`);

const byProfile = new Map();
for (const suite of suites) {
    const group = byProfile.get(suite.profile) ?? [];
    group.push(suite);
    byProfile.set(suite.profile, group);
}
for (const [profile, profileSuites] of byProfile) {
    const paths = profileSuites.map((suite) => suite.path);
    const matchPath = paths.length === 1 ? paths[0] : `{${paths.join(",")}}`;
    console.log(`test:unit: ${profile} — ${profileSuites.map((suite) => suite.id).join(", ")}`);
    const status = run(forge, ["test", "--match-path", matchPath], {
        env: { ...childEnv, FOUNDRY_PROFILE: profile },
    });
    if (status !== 0) fail(`profile ${profile} failed (Forge exit ${status})`, status);
}

console.log(`test:unit: PASS (${suites.length} suite(s))`);

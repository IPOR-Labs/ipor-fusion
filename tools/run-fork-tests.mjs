#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { config as loadEnv } from "dotenv";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const defaultCatalog = resolve(repoRoot, "config/test-suites.json");
const validator = resolve(repoRoot, "tools/validate-test-suites.mjs");

function fail(code, message, exitCode = 1) {
    console.error(`test:fork: ${code}: ${message}`);
    process.exit(exitCode);
}

function parsePositiveInteger(flag, value) {
    if (!/^[1-9][0-9]*$/.test(value ?? "")) fail("INVALID_ARGUMENT", `${flag} must be a positive integer`, 2);
    const parsed = Number(value);
    if (!Number.isSafeInteger(parsed)) {
        fail("INVALID_ARGUMENT", `${flag} is outside JavaScript's safe integer range`, 2);
    }
    return parsed;
}

function parseArgs(argv) {
    const values = {};
    for (let index = 0; index < argv.length; index += 2) {
        const flag = argv[index];
        const value = argv[index + 1];
        if (!value || !["--chain", "--suite", "--block", "--catalog"].includes(flag)) {
            fail("INVALID_ARGUMENT", "expected --chain <id> --suite <name> --block <number>", 2);
        }
        if (Object.hasOwn(values, flag)) fail("INVALID_ARGUMENT", `duplicate ${flag}`, 2);
        values[flag] = value;
    }
    for (const flag of ["--chain", "--suite", "--block"]) {
        if (!values[flag]) fail("INVALID_ARGUMENT", `missing ${flag}`, 2);
    }
    if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(values["--suite"])) {
        fail("INVALID_ARGUMENT", "--suite must be a lowercase catalog group", 2);
    }
    return {
        chainId: parsePositiveInteger("--chain", values["--chain"]),
        suiteGroup: values["--suite"],
        block: parsePositiveInteger("--block", values["--block"]),
        catalog: resolve(values["--catalog"] ?? defaultCatalog),
    };
}

function run(command, args, options = {}) {
    const result = spawnSync(command, args, {
        cwd: repoRoot,
        env: options.env ?? process.env,
        encoding: "utf8",
        stdio: options.stdio ?? "inherit",
    });
    if (result.error) fail("FORGE_UNAVAILABLE", `cannot start ${command}: ${result.error.message}`, 2);
    return result.status ?? 1;
}

const input = parseArgs(process.argv.slice(2));
const validationStatus = run(process.execPath, [validator, input.catalog]);
if (validationStatus !== 0) {
    fail("INVALID_CATALOG", `catalog validation failed (exit ${validationStatus})`, validationStatus);
}

let catalog;
try {
    catalog = JSON.parse(readFileSync(input.catalog, "utf8"));
} catch (error) {
    fail("INVALID_CATALOG", `cannot read ${input.catalog}: ${error.message}`, 2);
}

const forkSuites = catalog.suites.filter((suite) => suite.fixture !== "local-deployment");
const supportedChains = new Set(forkSuites.map((suite) => suite.chainId));
if (!supportedChains.has(input.chainId)) {
    fail("UNSUPPORTED_CHAIN", `chain ${input.chainId} is not in the fork catalog`);
}

const supportedGroups = new Set(catalog.suites.map((suite) => suite.group));
if (!supportedGroups.has(input.suiteGroup)) {
    fail("UNSUPPORTED_SUITE", `suite ${input.suiteGroup} is not in the catalog`);
}

const selected = forkSuites.filter((suite) => suite.chainId === input.chainId && suite.group === input.suiteGroup);
if (selected.length === 0) {
    fail("EMPTY_SELECTION", `no fork suites match chain ${input.chainId} and suite ${input.suiteGroup}`);
}

const rpcNames = new Set(selected.map((suite) => suite.rpc));
if (rpcNames.size !== 1) fail("INVALID_CATALOG", "selected suites do not use exactly one provider variable");
const [rpcName] = rpcNames;

loadEnv({ path: process.env.FUSION_ENV_FILE ?? resolve(repoRoot, ".env"), quiet: true });
if (!process.env[rpcName]) {
    fail("RPC_UNAVAILABLE", `${rpcName} is not set; copy .env.example to .env`);
}

const profiles = new Set(selected.map((suite) => suite.profile));
if (profiles.size !== 1) fail("INVALID_CATALOG", "selected suites do not use exactly one Foundry profile");
const [profile] = profiles;

const paths = selected.map((suite) => suite.path);
const matchPath = paths.length === 1 ? paths[0] : `{${paths.join(",")}}`;
const forge = process.env.FORGE_BIN || "forge";
const childEnv = {
    ...process.env,
    FOUNDRY_PROFILE: profile,
    FUSION_FORK_BLOCK: String(input.block),
};

console.log(
    `test:fork: chain=${input.chainId} suite=${input.suiteGroup} block=${input.block} profile=${profile} suites=${selected.length}`,
);
const status = run(forge, ["test", "--match-path", matchPath], { env: childEnv });
if (status !== 0) fail("FORGE_FAILED", `Forge exited with ${status}`, status);

console.log(`test:fork: PASS (${selected.length} suite(s), block ${input.block})`);

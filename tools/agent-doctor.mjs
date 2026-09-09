#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import process from "node:process";
import { fileURLToPath } from "node:url";
import { parse as parseEnv } from "dotenv";

const defaultRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const expectedFoundry = "1.7.1";

function usageError(message) {
    console.error(`agent:doctor: INVALID_ARGUMENT: ${message}`);
    process.exit(2);
}

function parseArgs(argv) {
    let json = false;
    let root = defaultRoot;
    let rpc = false;
    let chainId;
    let block;
    for (let index = 0; index < argv.length; index += 1) {
        if (argv[index] === "--json") {
            json = true;
        } else if (argv[index] === "--rpc") {
            rpc = true;
        } else if (argv[index] === "--chain" && argv[index + 1]) {
            chainId = parsePositiveInteger("--chain", argv[index + 1]);
            index += 1;
        } else if (argv[index] === "--block" && argv[index + 1]) {
            block = parsePositiveInteger("--block", argv[index + 1]);
            index += 1;
        } else if (argv[index] === "--root" && argv[index + 1]) {
            root = resolve(argv[index + 1]);
            index += 1;
        } else {
            usageError(`unknown or incomplete argument ${JSON.stringify(argv[index])}`);
        }
    }
    if (rpc && (!chainId || !block)) usageError("--rpc requires --chain <id> and --block <number>");
    if (!rpc && (chainId || block)) usageError("--chain and --block require --rpc");
    return { json, root, rpc, chainId, block };
}

function parsePositiveInteger(flag, value) {
    if (!/^[1-9][0-9]*$/.test(value)) usageError(`${flag} must be a positive integer`);
    const parsed = Number(value);
    if (!Number.isSafeInteger(parsed)) usageError(`${flag} is outside JavaScript's safe integer range`);
    return parsed;
}

function readJson(path) {
    try {
        return JSON.parse(readFileSync(path, "utf8"));
    } catch (error) {
        return { error: error.message };
    }
}

function command(commandName, args, root) {
    const result = spawnSync(commandName, args, {
        cwd: root,
        encoding: "utf8",
        env: process.env,
    });
    return {
        status: result.status,
        stdout: result.stdout ?? "",
        stderr: result.stderr ?? "",
        error: result.error?.message,
    };
}

function versionNumber(value) {
    return value?.trim().replace(/^v/, "");
}

async function rpcRequest(url, method, params) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 10_000);
    try {
        const response = await fetch(url, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
            signal: controller.signal,
        });
        if (!response.ok) return { transportError: true };
        const body = await response.json();
        if (body.error) return { rpcError: true };
        return { result: body.result };
    } catch {
        return { transportError: true };
    } finally {
        clearTimeout(timeout);
    }
}

const { json, root, rpc, chainId, block } = parseArgs(process.argv.slice(2));
const checks = [];
const add = (id, status, message, remediation) => {
    const check = { id, status, message };
    if (remediation) check.remediation = remediation;
    checks.push(check);
};

const packageJson = readJson(resolve(root, "package.json"));
if (packageJson.error) {
    add("package-json", "error", "package.json is missing or invalid", "Run the command from an ipor-fusion checkout.");
} else {
    add("package-json", "ok", "package.json is readable");
}

const expectedNode = packageJson.engines?.node;
const actualNode = versionNumber(process.version);
if (!expectedNode) {
    add("node-version", "error", "package.json does not declare engines.node");
} else if (actualNode === expectedNode) {
    add("node-version", "ok", `Node.js ${actualNode} matches package.json`);
} else {
    add(
        "node-version",
        "warning",
        `Node.js ${actualNode} differs from declared ${expectedNode}`,
        `Use Node.js ${expectedNode} for reproduced results.`,
    );
}

const npmVersion = command("npm", ["--version"], root);
const expectedNpm = packageJson.engines?.npm;
const actualNpm = versionNumber(npmVersion.stdout);
if (npmVersion.error || npmVersion.status !== 0) {
    add("npm-version", "error", "npm is unavailable", "Install the Node.js/npm versions declared in package.json.");
} else if (actualNpm === expectedNpm) {
    add("npm-version", "ok", `npm ${actualNpm} matches package.json`);
} else {
    add(
        "npm-version",
        "warning",
        `npm ${actualNpm} differs from declared ${expectedNpm ?? "version missing"}`,
        expectedNpm ? `Use npm ${expectedNpm} for reproduced installs.` : "Declare engines.npm in package.json.",
    );
}

const forgeVersion = command("forge", ["--version"], root);
const actualForge = forgeVersion.stdout.match(/^forge Version:\s*([^\s]+)/m)?.[1];
if (forgeVersion.error || forgeVersion.status !== 0) {
    add("foundry-version", "error", "forge is unavailable", `Install Foundry v${expectedFoundry} with foundryup.`);
} else if (actualForge === expectedFoundry) {
    add("foundry-version", "ok", `Foundry ${actualForge} matches the repository pin`);
} else {
    add(
        "foundry-version",
        "error",
        `Foundry ${actualForge ?? "version unknown"} differs from required ${expectedFoundry}`,
        `Run foundryup --install v${expectedFoundry}.`,
    );
}

if (!existsSync(resolve(root, "node_modules"))) {
    add("node-dependencies", "error", "node_modules is missing", "Run npm ci.");
} else {
    const npmList = command("npm", ["ls", "--depth=0", "--json"], root);
    if (npmList.error || npmList.status !== 0) {
        add("node-dependencies", "error", "installed Node.js dependencies do not match the lockfile", "Run npm ci.");
    } else {
        add("node-dependencies", "ok", "top-level Node.js dependencies are installed");
    }
}

const submodules = command("git", ["submodule", "status", "--recursive"], root);
if (submodules.error || submodules.status !== 0) {
    add(
        "git-submodules",
        "error",
        "Git submodule status could not be read",
        "Run git submodule update --init --recursive from the checkout.",
    );
} else {
    const lines = submodules.stdout.split("\n").filter(Boolean);
    const invalid = lines.filter((line) => ["-", "+", "U"].includes(line[0]));
    if (lines.length === 0 || invalid.length > 0) {
        add(
            "git-submodules",
            "error",
            invalid.length > 0
                ? `${invalid.length} submodule(s) are missing or differ from the recorded commits`
                : "no initialized submodules were found",
            "Run git submodule update --init --recursive.",
        );
    } else {
        add("git-submodules", "ok", `${lines.length} submodule checkout(s) match recorded commits`);
    }
}

let exampleVariables = [];
try {
    exampleVariables = readFileSync(resolve(root, ".env.example"), "utf8")
        .split("\n")
        .map((line) => line.match(/^([A-Z][A-Z0-9_]*)=/)?.[1])
        .filter(Boolean);
} catch {
    add("rpc-variable-list", "error", ".env.example is missing", "Restore .env.example from the repository.");
}

let fileEnvironment = {};
try {
    fileEnvironment = parseEnv(readFileSync(resolve(root, ".env")));
} catch {
    // .env is optional for local work.
}

for (const name of exampleVariables) {
    const present = Boolean(process.env[name] || fileEnvironment[name]);
    add(
        `env:${name}`,
        present ? "ok" : "warning",
        `${name} is ${present ? "set" : "missing"}`,
        present ? undefined : "Required only for tests on that network; copy .env.example to .env.",
    );
}

if (rpc) {
    const catalog = readJson(resolve(root, "config/test-suites.json"));
    const networkSuites = Array.isArray(catalog.suites)
        ? catalog.suites.filter((suite) => suite.fixture !== "local-deployment" && suite.chainId === chainId)
        : [];
    const rpcNames = new Set(networkSuites.map((suite) => suite.rpc));
    const probes = new Map(
        networkSuites
            .filter((suite) => suite.stateProbe)
            .map((suite) => [suite.stateProbe.address.toLowerCase(), suite.stateProbe]),
    );

    // One provider per chain, but a chain may have several probes: each suite
    // names the state it needs, and all of them are checked.
    if (networkSuites.length === 0 || rpcNames.size !== 1 || probes.size === 0) {
        add(
            `rpc:${chainId}`,
            "error",
            `RPC_CHECK_UNCONFIGURED: chain ${chainId} does not have exactly one catalogued provider and at least one state probe`,
        );
    } else {
        const [rpcName] = rpcNames;
        const rpcUrl = process.env[rpcName] || fileEnvironment[rpcName];
        if (!rpcUrl) {
            add(`rpc:${chainId}`, "error", `RPC_UNAVAILABLE: ${rpcName} is not set`);
        } else {
            const chain = await rpcRequest(rpcUrl, "eth_chainId", []);
            if (chain.transportError || chain.rpcError || typeof chain.result !== "string") {
                add(`rpc:${chainId}`, "error", `RPC_UNAVAILABLE: ${rpcName} did not return a chain ID`);
            } else {
                const actualChainId = Number.parseInt(chain.result, 16);
                if (actualChainId !== chainId) {
                    add(
                        `rpc:${chainId}`,
                        "error",
                        `CHAIN_MISMATCH: expected chain ${chainId}, provider reports ${actualChainId}`,
                    );
                } else {
                    add(`rpc:${chainId}`, "ok", `chain ID ${chainId} matches`);
                    const unavailable = [];
                    for (const probe of probes.values()) {
                        const historical = await rpcRequest(rpcUrl, "eth_getCode", [
                            probe.address,
                            `0x${block.toString(16)}`,
                        ]);
                        if (
                            historical.transportError ||
                            historical.rpcError ||
                            typeof historical.result !== "string" ||
                            historical.result === "0x"
                        ) {
                            unavailable.push(probe.address);
                        }
                    }
                    if (unavailable.length > 0) {
                        add(
                            `rpc-history:${chainId}`,
                            "error",
                            `HISTORICAL_STATE_UNAVAILABLE: code probe failed at block ${block} for ${unavailable.join(", ")}`,
                        );
                    } else {
                        add(
                            `rpc-history:${chainId}`,
                            "ok",
                            `historical code is available at block ${block} for ${probes.size} probe(s)`,
                        );
                    }
                }
            }
        }
    }
}

const status = checks.some((check) => check.status === "error")
    ? "error"
    : checks.some((check) => check.status === "warning")
      ? "warning"
      : "ok";
const report = { schemaVersion: 1, status, networkChecks: rpc, checks };

if (json) {
    console.log(JSON.stringify(report, null, 2));
} else {
    console.log(`agent:doctor: ${status.toUpperCase()} (${rpc ? "RPC enabled" : "offline"})`);
    for (const check of checks) {
        console.log(`[${check.status.toUpperCase()}] ${check.id}: ${check.message}`);
        if (check.remediation) console.log(`  -> ${check.remediation}`);
    }
}

process.exit(status === "error" ? 1 : 0);

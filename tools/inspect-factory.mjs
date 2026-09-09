#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { parse as parseEnv } from "dotenv";

const repoRoot = resolve(import.meta.dirname, "..");
const defaultManifest = resolve(repoRoot, "deployments/1/factories.json");
const implementationSlot = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

function fail(code, message, exitCode = 1) {
    console.error(`factory:inspect: ${code}: ${message}`);
    process.exit(exitCode);
}

function positive(flag, value) {
    if (!/^[1-9][0-9]*$/.test(value ?? "")) fail("INVALID_ARGUMENT", `${flag} must be a positive integer`, 2);
    const number = Number(value);
    if (!Number.isSafeInteger(number)) fail("INVALID_ARGUMENT", `${flag} is outside the safe integer range`, 2);
    return number;
}

function parseArgs(argv) {
    const values = {};
    for (let index = 0; index < argv.length; index += 2) {
        const flag = argv[index];
        const value = argv[index + 1];
        if (!value || !["--chain", "--deployment", "--block", "--caller", "--manifest"].includes(flag)) {
            fail("INVALID_ARGUMENT", "expected --chain <id> --deployment <id> --block <number> --caller <address>", 2);
        }
        if (Object.hasOwn(values, flag)) fail("INVALID_ARGUMENT", `duplicate ${flag}`, 2);
        values[flag] = value;
    }
    for (const flag of ["--chain", "--deployment", "--block", "--caller"]) {
        if (!values[flag]) fail("INVALID_ARGUMENT", `missing ${flag}`, 2);
    }
    if (!/^0x[0-9a-fA-F]{40}$/.test(values["--caller"])) {
        fail("INVALID_ARGUMENT", "--caller must be a 20-byte address", 2);
    }
    return {
        chainId: positive("--chain", values["--chain"]),
        deploymentId: values["--deployment"],
        blockNumber: positive("--block", values["--block"]),
        caller: values["--caller"],
        manifestPath: resolve(values["--manifest"] ?? defaultManifest),
    };
}

function json(path, code) {
    try {
        return JSON.parse(readFileSync(path, "utf8"));
    } catch {
        fail(code, `cannot read ${path}`, 2);
    }
}

function cast(args) {
    const result = spawnSync("cast", args, { cwd: repoRoot, encoding: "utf8" });
    if (result.error || result.status !== 0) fail("CAST_FAILED", `cast ${args[0]} failed`, 2);
    return result.stdout.trim();
}

function canonicalType(parameter) {
    if (!parameter.type.startsWith("tuple")) return parameter.type;
    return `(${parameter.components.map(canonicalType).join(",")})${parameter.type.slice(5)}`;
}

function functionSignature(entry, withOutputs = false) {
    const inputs = entry.inputs.map(canonicalType).join(",");
    if (!withOutputs) return `${entry.name}(${inputs})`;
    return `${entry.name}(${inputs})(${entry.outputs.map(canonicalType).join(",")})`;
}

async function rpc(url, method, params) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 15_000);
    try {
        const response = await fetch(url, {
            method: "POST",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
            signal: controller.signal,
        });
        if (!response.ok) return { error: true };
        const body = await response.json();
        if (body.error) return { error: true };
        return { result: body.result };
    } catch {
        return { error: true };
    } finally {
        clearTimeout(timeout);
    }
}

function checksum(address) {
    return cast(["to-check-sum-address", address]);
}

function codeHash(code) {
    return cast(["keccak", code]);
}

const input = parseArgs(process.argv.slice(2));
const manifest = json(input.manifestPath, "INVALID_MANIFEST");
const deployment = manifest.deployments?.find((entry) => entry.id === input.deploymentId);
if (!deployment) fail("UNKNOWN_DEPLOYMENT", `deployment ${input.deploymentId} is not in the manifest`);
if (manifest.chainId !== input.chainId || deployment.chainId !== input.chainId) {
    fail(
        "CHAIN_MISMATCH",
        `requested chain ${input.chainId} does not match manifest chain ${manifest.chainId}/${deployment.chainId}`,
    );
}
if (deployment.status !== "candidate" && deployment.status !== "verified") {
    fail("UNSUPPORTED_DEPLOYMENT", `status ${deployment.status} cannot be inspected operationally`);
}

const catalog = json(resolve(repoRoot, "config/test-suites.json"), "INVALID_CATALOG");
const providers = new Set(
    catalog.suites
        .filter((suite) => suite.fixture !== "local-deployment" && suite.chainId === input.chainId)
        .map((suite) => suite.rpc),
);
if (providers.size !== 1) fail("RPC_UNAVAILABLE", `chain ${input.chainId} has no unique provider variable`);
const [providerName] = providers;
let envFile = {};
try {
    envFile = parseEnv(readFileSync(process.env.FUSION_ENV_FILE ?? resolve(repoRoot, ".env")));
} catch {
    // The environment may provide the value directly.
}
const rpcUrl = process.env[providerName] || envFile[providerName];
if (!rpcUrl) fail("RPC_UNAVAILABLE", `${providerName} is not set`);

const chain = await rpc(rpcUrl, "eth_chainId", []);
if (chain.error || typeof chain.result !== "string") fail("RPC_UNAVAILABLE", `${providerName} did not answer`);
const actualChainId = Number.parseInt(chain.result, 16);
if (actualChainId !== input.chainId) {
    fail("CHAIN_MISMATCH", `requested chain ${input.chainId}, provider reports ${actualChainId}`);
}

const blockTag = `0x${input.blockNumber.toString(16)}`;
const block = await rpc(rpcUrl, "eth_getBlockByNumber", [blockTag, false]);
if (block.error || !block.result?.hash) {
    fail("HISTORICAL_STATE_UNAVAILABLE", `block ${input.blockNumber} is unavailable`);
}

const proxyCodeResult = await rpc(rpcUrl, "eth_getCode", [deployment.address, blockTag]);
if (proxyCodeResult.error) fail("RPC_UNAVAILABLE", "proxy code read failed");
if (!proxyCodeResult.result || proxyCodeResult.result === "0x") {
    fail("NO_CODE", `no proxy code at ${deployment.address} on block ${input.blockNumber}`);
}

const slot = deployment.proxy.implementationSlot ?? implementationSlot;
const storage = await rpc(rpcUrl, "eth_getStorageAt", [deployment.address, slot, blockTag]);
if (storage.error || !/^0x[0-9a-fA-F]{64}$/.test(storage.result ?? "")) {
    fail("UNSUPPORTED_FACTORY_VERSION", "implementation slot could not be read");
}
const observedImplementation = checksum(`0x${storage.result.slice(-40)}`);
if (observedImplementation.toLowerCase() !== deployment.proxy.implementation?.toLowerCase()) {
    fail(
        "IMPLEMENTATION_MISMATCH",
        `manifest expects ${deployment.proxy.implementation}, observed ${observedImplementation}`,
    );
}

const implementationCodeResult = await rpc(rpcUrl, "eth_getCode", [observedImplementation, blockTag]);
if (implementationCodeResult.error) fail("RPC_UNAVAILABLE", "implementation code read failed");
if (!implementationCodeResult.result || implementationCodeResult.result === "0x") {
    fail("NO_CODE", `no implementation code at ${observedImplementation} on block ${input.blockNumber}`);
}

const abiPath = resolve(repoRoot, deployment.interface.abiPath);
const abiBytes = readFileSync(abiPath);
if (createHash("sha256").update(abiBytes).digest("hex") !== deployment.interface.abiSha256) {
    fail("UNSUPPORTED_FACTORY_VERSION", "manifest ABI hash does not match the referenced file");
}
const abi = JSON.parse(abiBytes);

async function call(name, args = []) {
    const entries = abi.filter((entry) => entry.type === "function" && entry.name === name);
    if (entries.length !== 1) fail("UNSUPPORTED_FACTORY_VERSION", `ABI does not contain exactly one ${name}`);
    const entry = entries[0];
    const data = cast(["calldata", functionSignature(entry), ...args.map(String)]);
    const response = await rpc(rpcUrl, "eth_call", [{ to: deployment.address, from: input.caller, data }, blockTag]);
    if (response.error || typeof response.result !== "string") {
        fail("UNSUPPORTED_FACTORY_VERSION", `${name} reverted or returned no data`);
    }
    try {
        return JSON.parse(cast(["decode-abi", "--json", functionSignature(entry, true), response.result]));
    } catch {
        fail("UNSUPPORTED_FACTORY_VERSION", `${name} output does not match the manifest ABI`);
    }
}

const factoryAddresses = (await call("getFactoryAddresses"))[0];
const baseAddresses = (await call("getBaseAddresses"))[0];
const version = (await call("getFusionFactoryVersion"))[0];
const priceOracleMiddleware = (await call("getPriceOracleMiddleware"))[0];
const burnRequestFeeFuse = (await call("getBurnRequestFeeFuseAddress"))[0];
const burnRequestFeeBalanceFuse = (await call("getBurnRequestFeeBalanceFuseAddress"))[0];
const vestingPeriodSeconds = (await call("getVestingPeriodInSeconds"))[0];
const withdrawWindowSeconds = (await call("getWithdrawWindowInSeconds"))[0];
const [effectivePackages, isCustom] = await call("getBusinessClientFeePackages", [input.caller]);
const [globalPackages] = await call("getDaoFeePackages");

const packageObject = ([managementFeeBps, performanceFeeBps, feeRecipient]) => ({
    managementFeeBps,
    performanceFeeBps,
    feeRecipient,
});
const names = (values, keys) => Object.fromEntries(keys.map((key, index) => [key, values[index]]));

const report = {
    schemaVersion: 1,
    status: "ok",
    chainId: input.chainId,
    blockNumber: input.blockNumber,
    blockHash: block.result.hash,
    deploymentId: deployment.id,
    caller: checksum(input.caller),
    result: {
        proxy: {
            address: checksum(deployment.address),
            runtimeCodeHash: codeHash(proxyCodeResult.result),
            implementationSlot: slot,
            implementation: observedImplementation,
            implementationRuntimeCodeHash: codeHash(implementationCodeResult.result),
        },
        factoryVersion: version,
        components: {
            factories: names(factoryAddresses, [
                "accessManagerFactory",
                "plasmaVaultFactory",
                "feeManagerFactory",
                "withdrawManagerFactory",
                "rewardsManagerFactory",
                "contextManagerFactory",
                "priceManagerFactory",
            ]),
            bases: names(baseAddresses, [
                "plasmaVaultCoreBase",
                "accessManagerBase",
                "priceManagerBase",
                "withdrawManagerBase",
                "rewardsManagerBase",
                "contextManagerBase",
            ]),
            priceOracleMiddleware,
            burnRequestFeeFuse,
            burnRequestFeeBalanceFuse,
        },
        timing: { vestingPeriodSeconds, withdrawWindowSeconds },
        fees: {
            effectiveForCaller: {
                isCustom,
                packages: effectivePackages.map(packageObject),
            },
            globalPackages: globalPackages.map(packageObject),
        },
    },
    warnings: [
        `manifest status remains ${deployment.status}; inspection does not promote it`,
        "configuration and caller-specific fees are observations at one block, not permanent constants",
    ],
    references: {
        manifest: "deployments/1/factories.json",
        abi: deployment.interface.abiPath,
    },
};

console.log(JSON.stringify(report, null, 2));

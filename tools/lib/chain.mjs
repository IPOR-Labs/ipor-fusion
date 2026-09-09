// Read-only chain access shared by the vault tooling.
//
// The provider URL is resolved from the test catalog's variable name and never
// printed: callers get the variable name to report, not its value.

import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { parse as parseEnv } from "dotenv";

export const repoRoot = resolve(import.meta.dirname, "../..");

export class ChainError extends Error {
    constructor(code, message) {
        super(message);
        this.code = code;
    }
}

/// Name of the environment variable that holds the provider for a chain,
/// taken from the classified fork suites so that one catalog stays the source.
export function providerVariable(chainId) {
    const catalog = JSON.parse(readFileSync(resolve(repoRoot, "config/test-suites.json"), "utf8"));
    const names = new Set(
        catalog.suites
            .filter((suite) => suite.fixture !== "local-deployment" && suite.chainId === chainId)
            .map((suite) => suite.rpc),
    );
    if (names.size !== 1) throw new ChainError("RPC_UNAVAILABLE", `chain ${chainId} has no unique provider variable`);
    return [...names][0];
}

export function providerUrl(chainId) {
    const name = providerVariable(chainId);
    let fromFile = {};
    try {
        fromFile = parseEnv(readFileSync(process.env.FUSION_ENV_FILE ?? resolve(repoRoot, ".env")));
    } catch {
        // The environment may provide the value directly.
    }
    const url = process.env[name] || fromFile[name];
    if (!url) throw new ChainError("RPC_UNAVAILABLE", `${name} is not set`);
    return { name, url };
}

export async function rpc(url, method, params) {
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

export function cast(args) {
    const result = spawnSync("cast", args, { cwd: repoRoot, encoding: "utf8" });
    if (result.error || result.status !== 0) throw new ChainError("CAST_FAILED", `cast ${args[0]} failed`);
    return result.stdout.trim();
}

export const checksum = (address) => cast(["to-check-sum-address", address]);

export function canonicalType(parameter) {
    if (!parameter.type.startsWith("tuple")) return parameter.type;
    return `(${parameter.components.map(canonicalType).join(",")})${parameter.type.slice(5)}`;
}

export function functionSignature(entry, withOutputs = false) {
    const inputs = entry.inputs.map(canonicalType).join(",");
    if (!withOutputs) return `${entry.name}(${inputs})`;
    return `${entry.name}(${inputs})(${entry.outputs.map(canonicalType).join(",")})`;
}

/// Finds exactly one function entry by name in a deployed ABI.
export function abiFunction(abi, name) {
    const entries = abi.filter((entry) => entry.type === "function" && entry.name === name);
    if (entries.length !== 1) {
        throw new ChainError("UNSUPPORTED_FACTORY_VERSION", `ABI does not contain exactly one ${name}`);
    }
    return entries[0];
}

/// eth_call at a pinned block, decoded through the deployed ABI.
export async function callAt(url, { to, from, blockTag }, abi, name, args = []) {
    const entry = abiFunction(abi, name);
    const data = cast(["calldata", functionSignature(entry), ...args.map(String)]);
    const response = await rpc(url, "eth_call", [{ to, from, data }, blockTag]);
    if (response.error || typeof response.result !== "string") {
        throw new ChainError("UNSUPPORTED_FACTORY_VERSION", `${name} reverted or returned no data`);
    }
    try {
        return JSON.parse(cast(["decode-abi", "--json", functionSignature(entry, true), response.result]));
    } catch {
        throw new ChainError("UNSUPPORTED_FACTORY_VERSION", `${name} output does not match the manifest ABI`);
    }
}

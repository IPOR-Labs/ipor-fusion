// Loading and checking of a vault creation input (config/vaults/*.json).
//
// Kept separate from the CLI so that planning, simulation and verification all
// answer the same question the same way: is this input well formed, and does it
// agree with the deployment registry? Nothing here reads RPC.

import { existsSync, readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { resolve } from "node:path";
import { validateSchema } from "./json-schema.mjs";

export const repoRoot = resolve(import.meta.dirname, "../..");
export const schemaPath = resolve(repoRoot, "config/vaults/vault-creation.schema.json");
export const defaultConfigPath = resolve(repoRoot, "config/vaults/example.json");

export const operationForVariant = {
    "permissionless-clone": "clone(string,string,address,uint256,address,uint256)",
    "supervised-clone": "cloneSupervised(string,string,address,uint256,address,uint256)",
};

export class InputError extends Error {
    constructor(code, message) {
        super(message);
        this.code = code;
    }
}

export function readJsonOrThrow(path, code) {
    try {
        return JSON.parse(readFileSync(path, "utf8"));
    } catch (error) {
        throw new InputError(code, `cannot read ${path}: ${error.message}`);
    }
}

/// Hash of the exact bytes on disk, so that a plan can name the input it was
/// built from without copying it.
export function configHash(path) {
    return `0x${createHash("sha256").update(readFileSync(path)).digest("hex")}`;
}

/// FUSION_DEPLOYMENTS_DIR points the lookup at another registry root, so that a
/// staged or fixture registry can be checked without editing the real one.
export function manifestPathFor(chainId) {
    const root = process.env.FUSION_DEPLOYMENTS_DIR ?? resolve(repoRoot, "deployments");
    return resolve(root, `${chainId}/factories.json`);
}

/// Returns { findings, deployment }. An empty findings array means the input is
/// usable; `deployment` is the manifest entry it names, when that resolved.
export function checkVaultConfig(config) {
    const findings = [];
    const add = (code, where, message) => findings.push({ code, where, message });
    const schema = readJsonOrThrow(schemaPath, "SCHEMA_UNREADABLE");

    for (const error of validateSchema(config, schema)) {
        const [where, ...rest] = error.split(": ");
        add("INVALID_CONFIG", where, rest.join(": "));
    }

    const zero = (value) => typeof value === "string" && /^0x0{40}$/i.test(value);
    for (const [where, value] of [
        ["$.caller", config.caller],
        ["$.vault.owner", config.vault?.owner],
        ["$.vault.underlying.address", config.vault?.underlying?.address],
        ["$.fees.expected.feeRecipient", config.fees?.expected?.feeRecipient],
    ]) {
        if (zero(value)) add("INVALID_CONFIG", where, "the zero address is not a usable participant");
    }

    let deployment;
    if (Number.isInteger(config.chainId)) {
        const manifestPath = manifestPathFor(config.chainId);
        if (!existsSync(manifestPath)) {
            add("UNKNOWN_DEPLOYMENT", "$.chainId", `no manifest for chain ${config.chainId} at ${manifestPath}`);
        } else {
            const manifest = readJsonOrThrow(manifestPath, "MANIFEST_UNREADABLE");
            deployment = manifest.deployments?.find((entry) => entry.id === config.deploymentId);
            if (!deployment) {
                add(
                    "UNKNOWN_DEPLOYMENT",
                    "$.deploymentId",
                    `chain ${config.chainId} has no deployment "${config.deploymentId}"`,
                );
            } else if (deployment.status !== "verified") {
                add(
                    "UNVERIFIED_DEPLOYMENT",
                    "$.deploymentId",
                    `deployment status is "${deployment.status}", not "verified"`,
                );
            }
        }
    }

    if (deployment && typeof config.variant === "string") {
        const operation = operationForVariant[config.variant];
        const supported = deployment.interface?.supportedOperations ?? [];
        if (!supported.includes(operation)) {
            add(
                "UNSUPPORTED_VARIANT",
                "$.variant",
                `"${config.variant}" needs ${operation}, which "${config.deploymentId}" does not list as supported`,
            );
        }
    }

    return { findings, deployment };
}

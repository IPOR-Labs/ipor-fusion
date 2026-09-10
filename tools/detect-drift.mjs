#!/usr/bin/env node
// Compares verified deployments against the chain as it is now.
//
// Usage:
//   node tools/detect-drift.mjs [--chain <id>] [--deployment <id>]
//                               [--block <number|finalized|latest>]
//                               [--out <report.json>] [--json]
//
// With no selection flags every verified deployment in every production
// manifest is checked. --chain narrows the batch to one network, while
// --deployment selects one entry (chain 1 unless --chain is also given).
//
// Exit codes: 0 all selected entries are unchanged, 1 drift was detected,
// 2 at least one comparison could not be made. A batch report retains every
// result even when one provider is unavailable or another entry drifted.

import { existsSync, readdirSync, writeFileSync } from "node:fs";
import { relative, resolve } from "node:path";
import { ChainError, callAt, cast, checksum, providerUrl, rpc } from "./lib/chain.mjs";
import { InputError, manifestPathFor, readJsonOrThrow, repoRoot } from "./lib/vault-config.mjs";

function die(code, message, exitCode = 2) {
    console.error(`deployments:drift: ${code}: ${message}`);
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
        const flag = rest[index];
        const value = rest[index + 1];
        if (!value || !["--deployment", "--chain", "--block", "--out"].includes(flag)) {
            die(
                "INVALID_ARGUMENT",
                "expected [--chain <id>] [--deployment <id>] [--block <number|finalized|latest>] [--out <file>] [--json]",
            );
        }
        if (Object.hasOwn(values, flag)) die("INVALID_ARGUMENT", `duplicate ${flag}`);
        values[flag] = value;
    }
    if (values["--chain"] && !/^[1-9][0-9]*$/.test(values["--chain"])) {
        die("INVALID_ARGUMENT", "--chain must be a positive integer");
    }
    if (values["--block"] && !/^([1-9][0-9]*|finalized|latest)$/.test(values["--block"])) {
        die("INVALID_ARGUMENT", "--block must be a positive integer, finalized or latest");
    }
    if (!values["--chain"] && !values["--deployment"] && /^[0-9]+$/.test(values["--block"] ?? "")) {
        die("INVALID_ARGUMENT", "a numeric block across multiple chains is ambiguous; add --chain or use finalized/latest");
    }
    return {
        chainId: values["--chain"] ? Number(values["--chain"]) : values["--deployment"] ? 1 : undefined,
        deploymentId: values["--deployment"],
        block: values["--block"] ?? "finalized",
        outPath: values["--out"] ? resolve(values["--out"]) : undefined,
        asJson: values["--json"] === true,
    };
}

function registryRoot() {
    return resolve(process.env.FUSION_DEPLOYMENTS_DIR ?? resolve(repoRoot, "deployments"));
}

function selectedDeployments(input) {
    if (input.deploymentId) {
        const manifest = readJsonOrThrow(manifestPathFor(input.chainId), "MANIFEST_UNREADABLE");
        const deployment = manifest.deployments.find((entry) => entry.id === input.deploymentId);
        if (!deployment) {
            throw new ChainError("UNKNOWN_DEPLOYMENT", `${input.deploymentId} is not registered on chain ${input.chainId}`);
        }
        if (deployment.status !== "verified") {
            throw new ChainError(
                "UNVERIFIED_DEPLOYMENT",
                `${input.deploymentId} is "${deployment.status}"; there is no confirmed state to compare with`,
            );
        }
        return [deployment];
    }

    const root = registryRoot();
    let chainIds;
    try {
        chainIds = input.chainId
            ? [String(input.chainId)]
            : readdirSync(root, { withFileTypes: true })
                  .filter((entry) => entry.isDirectory() && /^[1-9][0-9]*$/.test(entry.name))
                  .map((entry) => entry.name)
                  .sort((left, right) => Number(left) - Number(right));
    } catch (error) {
        throw new InputError("MANIFEST_UNREADABLE", `cannot enumerate ${root}: ${error.message}`);
    }

    const deployments = [];
    for (const chainId of chainIds) {
        const manifest = readJsonOrThrow(resolve(root, chainId, "factories.json"), "MANIFEST_UNREADABLE");
        deployments.push(...manifest.deployments.filter((entry) => entry.status === "verified"));
    }
    if (deployments.length === 0) {
        throw new ChainError(
            "NO_VERIFIED_DEPLOYMENTS",
            input.chainId ? `chain ${input.chainId} has no verified deployments` : "the registry has no verified deployments",
        );
    }
    return deployments;
}

async function compareDeployment(deployment, blockSelection) {
    const reportPath = deployment.verification.reportPath;
    if (!reportPath || !existsSync(resolve(repoRoot, reportPath))) {
        throw new ChainError("REPORT_UNREADABLE", `the verification report ${reportPath} is missing`);
    }
    const confirmed = readJsonOrThrow(resolve(repoRoot, reportPath), "REPORT_UNREADABLE");

    const { name: providerName, url } = providerUrl(deployment.chainId);
    const chain = await rpc(url, "eth_chainId", []);
    if (chain.error || typeof chain.result !== "string") {
        throw new ChainError("RPC_UNAVAILABLE", `${providerName} did not answer`);
    }
    if (Number.parseInt(chain.result, 16) !== deployment.chainId) {
        throw new ChainError("CHAIN_MISMATCH", `provider reports chain ${Number.parseInt(chain.result, 16)}`);
    }

    const blockTag = /^[0-9]+$/.test(blockSelection)
        ? `0x${Number(blockSelection).toString(16)}`
        : blockSelection;
    const block = await rpc(url, "eth_getBlockByNumber", [blockTag, false]);
    if (block.error || !block.result?.hash) {
        throw new ChainError("BLOCK_UNAVAILABLE", `the provider did not serve block "${blockSelection}"`);
    }
    const blockNumber = Number.parseInt(block.result.number, 16);
    const at = { to: deployment.address, from: deployment.address, blockTag };

    const differences = [];
    const note = (field, confirmedValue, observedValue) => {
        if (String(confirmedValue).toLowerCase() !== String(observedValue).toLowerCase()) {
            differences.push({ field, confirmed: String(confirmedValue), observed: String(observedValue) });
        }
    };

    const storage = await rpc(url, "eth_getStorageAt", [
        deployment.address,
        deployment.proxy.implementationSlot,
        blockTag,
    ]);
    if (storage.error || !/^0x[0-9a-fA-F]{64}$/.test(storage.result ?? "")) {
        throw new ChainError("RPC_UNAVAILABLE", "the implementation slot could not be read");
    }
    const implementation = checksum(`0x${storage.result.slice(-40)}`);
    note("proxy.implementation", confirmed.identity.implementation.address, implementation);

    const codeOf = async (address) => {
        const code = await rpc(url, "eth_getCode", [address, blockTag]);
        if (code.error || typeof code.result !== "string") {
            throw new ChainError("RPC_UNAVAILABLE", `the code of ${address} could not be read`);
        }
        return code.result === "0x" ? null : cast(["keccak", code.result]);
    };
    note("proxy.runtimeCodeHash", confirmed.identity.proxy.runtimeCodeHash, await codeOf(deployment.address));
    note(
        "implementation.runtimeCodeHash",
        confirmed.identity.implementation.runtimeCodeHash,
        (await codeOf(implementation)) ?? "no code",
    );

    const abiNeeded =
        confirmed.identity.reportedFactoryVersion !== null &&
        confirmed.identity.reportedFactoryVersion !== undefined;
    const recordedComponents = confirmed.reads?.components?.entries ?? [];
    const membershipComponents = recordedComponents.filter(
        (component) => component.kind === "factory" || component.kind === "base",
    );
    const abi =
        abiNeeded || membershipComponents.length > 0
            ? readJsonOrThrow(resolve(repoRoot, deployment.interface.abiPath), "ABI_UNREADABLE")
            : null;

    if (abiNeeded) {
        try {
            const version = String((await callAt(url, at, abi, "getFusionFactoryVersion"))[0]);
            note("factoryVersion", confirmed.identity.reportedFactoryVersion, version);
        } catch (error) {
            if (error instanceof ChainError && error.code === "UNSUPPORTED_FACTORY_VERSION") {
                differences.push({
                    field: "interface.version",
                    confirmed: "answers getFusionFactoryVersion()",
                    observed: "does not answer the recorded ABI",
                });
            } else {
                throw error;
            }
        }
    }

    // Every dependency whose code hash was captured is checked for every kind
    // of factory. FusionFactory additionally exposes its current factory/base
    // membership, so only that kind gets the stronger configuration check.
    for (const component of recordedComponents) {
        if (!component.runtimeCodeHash) continue;
        const hash = await codeOf(component.address);
        note(`component.${component.id}.runtimeCodeHash`, component.runtimeCodeHash, hash ?? "no code");
    }

    if (deployment.kind === "fusion-factory" && membershipComponents.length > 0) {
        try {
            const factories = (await callAt(url, at, abi, "getFactoryAddresses"))[0].map((address) => checksum(address));
            const bases = (await callAt(url, at, abi, "getBaseAddresses"))[0].map((address) => checksum(address));
            const observed = new Set([...factories, ...bases].map((address) => address.toLowerCase()));
            for (const component of membershipComponents) {
                if (!observed.has(component.address.toLowerCase())) {
                    differences.push({
                        field: `component.${component.id}`,
                        confirmed: component.address,
                        observed: "no longer used by the factory",
                    });
                }
            }
        } catch (error) {
            if (error instanceof ChainError && error.code === "UNSUPPORTED_FACTORY_VERSION") {
                differences.push({
                    field: "interface.components",
                    confirmed: "answers the recorded component getters",
                    observed: "does not answer the recorded ABI",
                });
            } else {
                throw error;
            }
        }
    }

    return {
        schemaVersion: 1,
        status: differences.length === 0 ? "unchanged" : "drift",
        kind: "deployment-drift",
        chainId: deployment.chainId,
        deploymentId: deployment.id,
        deploymentKind: deployment.kind,
        confirmedAt: { blockNumber: confirmed.blockNumber, reportPath },
        observedAt: { blockNumber, blockHash: block.result.hash, tag: blockSelection },
        coverage: {
            identity: true,
            version: abiNeeded,
            componentCodeHashes: recordedComponents.filter((component) => component.runtimeCodeHash).length,
            componentMembership: deployment.kind === "fusion-factory" ? membershipComponents.length : 0,
        },
        differences,
        provider: { variable: providerName },
        warnings: [
            "this report never promotes a new version: a difference means the manifest and its evidence must be reviewed, re-verified and re-committed by a person",
            "historical fixtures stay pinned to their own blocks and are not affected by drift on a fresh block",
            "coverage is limited to identity, version and dependency facts captured in this deployment's verification report",
        ],
    };
}

const input = parseArgs(process.argv.slice(2));

let selections;
try {
    selections = selectedDeployments(input);
} catch (error) {
    if (!(error instanceof ChainError) && !(error instanceof InputError)) throw error;
    die(error.code, error.message, 2);
}

if (input.deploymentId) {
    const report = await compareDeployment(selections[0], input.block).catch((error) => {
        if (!(error instanceof ChainError) && !(error instanceof InputError)) throw error;
        die(error.code, error.message, 2);
    });
    const serialized = `${JSON.stringify(report, null, 4)}\n`;
    if (input.outPath) writeFileSync(input.outPath, serialized);
    if (input.asJson) {
        process.stdout.write(serialized);
    } else {
        console.log(
            `deployments:drift: ${report.status} for ${report.deploymentId} (confirmed at block ${report.confirmedAt.blockNumber}, observed at ${report.observedAt.blockNumber})`,
        );
        for (const difference of report.differences) {
            console.log(`  CHANGED ${difference.field}: ${difference.confirmed} -> ${difference.observed}`);
        }
        if (input.outPath) console.log(`  report written to ${relative(repoRoot, input.outPath)}`);
    }
    process.exit(report.status === "unchanged" ? 0 : 1);
}

const results = [];
for (const deployment of selections) {
    try {
        results.push(await compareDeployment(deployment, input.block));
    } catch (error) {
        if (!(error instanceof ChainError) && !(error instanceof InputError)) throw error;
        results.push({
            schemaVersion: 1,
            status: "unavailable",
            kind: "deployment-drift",
            chainId: deployment.chainId,
            deploymentId: deployment.id,
            deploymentKind: deployment.kind,
            error: { code: error.code, message: error.message },
        });
    }
}

const summary = {
    total: results.length,
    unchanged: results.filter((result) => result.status === "unchanged").length,
    drift: results.filter((result) => result.status === "drift").length,
    unavailable: results.filter((result) => result.status === "unavailable").length,
};
const status = summary.unavailable > 0 ? "unavailable" : summary.drift > 0 ? "drift" : "unchanged";
const report = {
    schemaVersion: 1,
    status,
    kind: "deployment-drift-batch",
    selection: { chainId: input.chainId ?? null, block: input.block, status: "verified" },
    summary,
    results,
    warnings: [
        "the batch includes every verified deployment in the selected registry scope",
        "an unavailable result means the full registry was not checked and uses exit code 2 even if another entry also drifted",
        "no result updates a manifest, a verification report or a historical fixture",
    ],
};
const serialized = `${JSON.stringify(report, null, 4)}\n`;
if (input.outPath) writeFileSync(input.outPath, serialized);

if (input.asJson) {
    process.stdout.write(serialized);
} else {
    console.log(
        `deployments:drift: ${status} for ${summary.total} verified deployment(s) (${summary.unchanged} unchanged, ${summary.drift} drift, ${summary.unavailable} unavailable)`,
    );
    for (const result of results) {
        console.log(`  ${result.status.padEnd(11)} chain ${result.chainId} ${result.deploymentId}`);
        for (const difference of result.differences ?? []) {
            console.log(`    CHANGED ${difference.field}: ${difference.confirmed} -> ${difference.observed}`);
        }
        if (result.error) console.log(`    ${result.error.code}: ${result.error.message}`);
    }
    if (input.outPath) console.log(`  report written to ${relative(repoRoot, input.outPath)}`);
}

process.exit(status === "unchanged" ? 0 : status === "drift" ? 1 : 2);

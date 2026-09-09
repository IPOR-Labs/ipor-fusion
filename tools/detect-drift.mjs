#!/usr/bin/env node
// Compares a verified deployment against the chain as it is now.
//
// Usage:
//   node tools/detect-drift.mjs [--deployment <id>] [--chain <id>]
//                               [--block <number|finalized>] [--out <report.json>] [--json]
//
// Exit codes: 0 unchanged, 1 drift detected, 2 the comparison could not be made
// (provider, block or artifact problem). Those three are deliberately distinct:
// an upgrade and a broken provider must never look the same in CI.
//
// This command reads. It never rewrites the manifest, never promotes a new
// version, and never touches the pinned blocks that historical fixtures use.

import { existsSync, writeFileSync } from "node:fs";
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
            die("INVALID_ARGUMENT", "expected [--deployment <id>] [--chain <id>] [--block <number|finalized>] [--out <file>] [--json]");
        }
        values[flag] = value;
    }
    if (values["--chain"] && !/^[1-9][0-9]*$/.test(values["--chain"])) {
        die("INVALID_ARGUMENT", "--chain must be a positive integer");
    }
    if (values["--block"] && !/^([1-9][0-9]*|finalized|latest)$/.test(values["--block"])) {
        die("INVALID_ARGUMENT", "--block must be a positive integer, finalized or latest");
    }
    return {
        chainId: Number(values["--chain"] ?? 1),
        deploymentId: values["--deployment"] ?? "ethereum-fusion-factory-cd05909c",
        block: values["--block"] ?? "finalized",
        outPath: values["--out"] ? resolve(values["--out"]) : undefined,
        asJson: values["--json"] === true,
    };
}

const input = parseArgs(process.argv.slice(2));

const report = await (async () => {
    const manifest = readJsonOrThrow(manifestPathFor(input.chainId), "MANIFEST_UNREADABLE");
    const deployment = manifest.deployments.find((entry) => entry.id === input.deploymentId);
    if (!deployment) throw new ChainError("UNKNOWN_DEPLOYMENT", `${input.deploymentId} is not registered on chain ${input.chainId}`);
    if (deployment.status !== "verified") {
        throw new ChainError("UNVERIFIED_DEPLOYMENT", `${input.deploymentId} is "${deployment.status}"; there is no confirmed state to compare with`);
    }
    const reportPath = deployment.verification.reportPath;
    if (!reportPath || !existsSync(resolve(repoRoot, reportPath))) {
        throw new ChainError("REPORT_UNREADABLE", `the verification report ${reportPath} is missing`);
    }
    const confirmed = readJsonOrThrow(resolve(repoRoot, reportPath), "REPORT_UNREADABLE");
    const abi = readJsonOrThrow(resolve(repoRoot, deployment.interface.abiPath), "ABI_UNREADABLE");

    const { name: providerName, url } = providerUrl(input.chainId);
    const chain = await rpc(url, "eth_chainId", []);
    if (chain.error || typeof chain.result !== "string") {
        throw new ChainError("RPC_UNAVAILABLE", `${providerName} did not answer`);
    }
    if (Number.parseInt(chain.result, 16) !== input.chainId) {
        throw new ChainError("CHAIN_MISMATCH", `provider reports chain ${Number.parseInt(chain.result, 16)}`);
    }

    const blockTag = /^[0-9]+$/.test(input.block) ? `0x${Number(input.block).toString(16)}` : input.block;
    const block = await rpc(url, "eth_getBlockByNumber", [blockTag, false]);
    if (block.error || !block.result?.hash) {
        throw new ChainError("BLOCK_UNAVAILABLE", `the provider did not serve block "${input.block}"`);
    }
    const blockNumber = Number.parseInt(block.result.number, 16);
    const at = { to: deployment.address, from: deployment.address, blockTag };

    const differences = [];
    const note = (field, confirmedValue, observedValue) => {
        if (String(confirmedValue).toLowerCase() !== String(observedValue).toLowerCase()) {
            differences.push({ field, confirmed: String(confirmedValue), observed: String(observedValue) });
        }
    };

    const storage = await rpc(url, "eth_getStorageAt", [deployment.address, deployment.proxy.implementationSlot, blockTag]);
    if (storage.error || !/^0x[0-9a-fA-F]{64}$/.test(storage.result ?? "")) {
        throw new ChainError("RPC_UNAVAILABLE", "the implementation slot could not be read");
    }
    const implementation = checksum(`0x${storage.result.slice(-40)}`);
    note("proxy.implementation", confirmed.identity.implementation.address, implementation);

    const codeOf = async (address) => {
        const code = await rpc(url, "eth_getCode", [address, blockTag]);
        if (code.error || typeof code.result !== "string") throw new ChainError("RPC_UNAVAILABLE", "a code read failed");
        return code.result === "0x" ? null : cast(["keccak", code.result]);
    };
    note("proxy.runtimeCodeHash", confirmed.identity.proxy.runtimeCodeHash, await codeOf(deployment.address));
    const implementationHash = await codeOf(implementation);
    note("implementation.runtimeCodeHash", confirmed.identity.implementation.runtimeCodeHash, implementationHash ?? "no code");

    // A version the ABI cannot read is drift, not an outage: the call answered.
    let version = null;
    try {
        version = String((await callAt(url, at, abi, "getFusionFactoryVersion"))[0]);
    } catch (error) {
        if (error instanceof ChainError && error.code === "UNSUPPORTED_FACTORY_VERSION") {
            differences.push({ field: "interface", confirmed: "answers the recorded ABI", observed: "does not answer the recorded ABI" });
        } else {
            throw error;
        }
    }
    if (version !== null) note("factoryVersion", confirmed.identity.reportedFactoryVersion, version);

    if (version !== null) {
        const factories = (await callAt(url, at, abi, "getFactoryAddresses"))[0].map((address) => checksum(address));
        const bases = (await callAt(url, at, abi, "getBaseAddresses"))[0].map((address) => checksum(address));
        const observed = new Map();
        for (const address of [...factories, ...bases]) observed.set(address.toLowerCase(), address);
        for (const component of confirmed.reads.components.entries) {
            if (component.kind !== "factory" && component.kind !== "base") continue;
            if (!observed.has(component.address.toLowerCase())) {
                differences.push({
                    field: `component.${component.id}`,
                    confirmed: component.address,
                    observed: "no longer used by the factory",
                });
                continue;
            }
            const hash = await codeOf(component.address);
            if (hash !== component.runtimeCodeHash) {
                differences.push({
                    field: `component.${component.id}.runtimeCodeHash`,
                    confirmed: component.runtimeCodeHash,
                    observed: hash ?? "no code",
                });
            }
        }
    }

    return {
        schemaVersion: 1,
        status: differences.length === 0 ? "unchanged" : "drift",
        kind: "deployment-drift",
        chainId: input.chainId,
        deploymentId: deployment.id,
        confirmedAt: { blockNumber: confirmed.blockNumber, reportPath },
        observedAt: { blockNumber, blockHash: block.result.hash, tag: input.block },
        differences,
        provider: { variable: providerName },
        warnings: [
            "this report never promotes a new version: a difference means the manifest and its evidence must be reviewed, re-verified and re-committed by a person",
            "historical fixtures stay pinned to their own blocks and are not affected by drift on a fresh block",
        ],
    };
})().catch((error) => {
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

#!/usr/bin/env node
// Builds one verifiable vault creation plan: the calldata, its target, the
// caller, the value, the deployment identity it was planned against and the fee
// package that identity reports for that caller at a pinned block.
//
// Usage:
//   node tools/plan-vault.mjs --config <config.json> --block <number> [--out <plan.json>]
//
// Exit codes: 0 planned, 1 refused, 2 bad input or unreadable file.
//
// It signs nothing and sends nothing. Every read is an eth_call or a storage
// read at the given historical block.

import { writeFileSync } from "node:fs";
import { relative, resolve } from "node:path";
import {
    ChainError,
    abiFunction,
    callAt,
    cast,
    checksum,
    functionSignature,
    providerUrl,
    rpc,
} from "./lib/chain.mjs";
import {
    InputError,
    checkVaultConfig,
    configHash,
    operationForVariant,
    readJsonOrThrow,
    repoRoot,
} from "./lib/vault-config.mjs";
import { firstArtifactError } from "./lib/artifact-schema.mjs";

function die(code, message) {
    console.error(`vault:plan: ${code}: ${message}`);
    process.exit(code === "INVALID_ARGUMENT" || code.endsWith("_UNREADABLE") ? 2 : 1);
}

function parseArgs(argv) {
    const values = {};
    for (let index = 0; index < argv.length; index += 2) {
        const flag = argv[index];
        const value = argv[index + 1];
        if (!value || !["--config", "--block", "--out"].includes(flag)) {
            die("INVALID_ARGUMENT", "expected --config <file> --block <number> [--out <file>]");
        }
        if (Object.hasOwn(values, flag)) die("INVALID_ARGUMENT", `duplicate ${flag}`);
        values[flag] = value;
    }
    for (const flag of ["--config", "--block"]) {
        if (!values[flag]) die("INVALID_ARGUMENT", `missing ${flag}`);
    }
    if (!/^[1-9][0-9]*$/.test(values["--block"])) die("INVALID_ARGUMENT", "--block must be a positive integer");
    return {
        configPath: resolve(values["--config"]),
        blockNumber: Number(values["--block"]),
        outPath: values["--out"] ? resolve(values["--out"]) : undefined,
    };
}

const input = parseArgs(process.argv.slice(2));

let config;
let deployment;
try {
    config = readJsonOrThrow(input.configPath, "CONFIG_UNREADABLE");
    const checked = checkVaultConfig(config);
    if (checked.findings.length > 0) {
        const first = checked.findings[0];
        die(first.code, `${relative(repoRoot, input.configPath)} ${first.where}: ${first.message}`);
    }
    deployment = checked.deployment;
} catch (error) {
    if (!(error instanceof InputError)) throw error;
    die(error.code, error.message);
}

const abiPath = resolve(repoRoot, deployment.interface.abiPath);
const abi = readJsonOrThrow(abiPath, "ABI_UNREADABLE");

const plan = await (async () => {
    const { name: providerName, url } = providerUrl(config.chainId);

    const chain = await rpc(url, "eth_chainId", []);
    if (chain.error || typeof chain.result !== "string") {
        throw new ChainError("RPC_UNAVAILABLE", `${providerName} did not answer`);
    }
    const observedChain = Number.parseInt(chain.result, 16);
    if (observedChain !== config.chainId) {
        throw new ChainError("CHAIN_MISMATCH", `config chain ${config.chainId}, provider reports ${observedChain}`);
    }

    const blockTag = `0x${input.blockNumber.toString(16)}`;
    const block = await rpc(url, "eth_getBlockByNumber", [blockTag, false]);
    if (block.error || !block.result?.hash) {
        throw new ChainError("HISTORICAL_STATE_UNAVAILABLE", `block ${input.blockNumber} is unavailable`);
    }

    // Identity: the plan is only valid for the implementation it was built for.
    const storage = await rpc(url, "eth_getStorageAt", [
        deployment.address,
        deployment.proxy.implementationSlot,
        blockTag,
    ]);
    if (storage.error || !/^0x[0-9a-fA-F]{64}$/.test(storage.result ?? "")) {
        throw new ChainError("IMPLEMENTATION_MISMATCH", "implementation slot could not be read");
    }
    const implementation = checksum(`0x${storage.result.slice(-40)}`);
    if (implementation.toLowerCase() !== deployment.proxy.implementation.toLowerCase()) {
        throw new ChainError(
            "IMPLEMENTATION_MISMATCH",
            `manifest expects ${deployment.proxy.implementation}, block ${input.blockNumber} has ${implementation}`,
        );
    }

    const at = { to: deployment.address, from: config.caller, blockTag };
    const version = String((await callAt(url, at, abi, "getFusionFactoryVersion"))[0]);
    if (deployment.interface.reportedVersion !== null && version !== deployment.interface.reportedVersion) {
        throw new ChainError(
            "UNSUPPORTED_FACTORY_VERSION",
            `manifest recorded version ${deployment.interface.reportedVersion}, block ${input.blockNumber} reports ${version}`,
        );
    }

    // Fees are selected by msg.sender, so they are read for the configured caller.
    const [clientPackages, isCustom] = await callAt(url, at, abi, "getBusinessClientFeePackages", [config.caller]);
    const [globalPackages] = await callAt(url, at, abi, "getDaoFeePackages");
    const observedSource = isCustom ? "business-client" : "dao-global";
    if (observedSource !== config.fees.packageSource) {
        throw new ChainError(
            "FEE_PACKAGE_MISMATCH",
            `config expects the ${config.fees.packageSource} list for ${config.caller}, the factory uses ${observedSource}`,
        );
    }
    const packages = isCustom ? clientPackages : globalPackages;
    if (config.fees.packageIndex >= packages.length) {
        throw new ChainError(
            "FEE_PACKAGE_MISMATCH",
            `package index ${config.fees.packageIndex} is out of bounds; the ${observedSource} list has ${packages.length} package(s)`,
        );
    }
    const [managementFeeBps, performanceFeeBps, feeRecipient] = packages[config.fees.packageIndex];
    const expected = config.fees.expected;
    const observed = {
        managementFeeBps: Number(managementFeeBps),
        performanceFeeBps: Number(performanceFeeBps),
        feeRecipient: checksum(feeRecipient),
    };
    for (const key of ["managementFeeBps", "performanceFeeBps"]) {
        if (observed[key] !== expected[key]) {
            throw new ChainError("FEE_PACKAGE_MISMATCH", `${key}: config expects ${expected[key]}, factory reports ${observed[key]}`);
        }
    }
    if (observed.feeRecipient.toLowerCase() !== expected.feeRecipient.toLowerCase()) {
        throw new ChainError(
            "FEE_PACKAGE_MISMATCH",
            `feeRecipient: config expects ${expected.feeRecipient}, factory reports ${observed.feeRecipient}`,
        );
    }

    const operation = operationForVariant[config.variant];
    const entry = abiFunction(abi, operation.slice(0, operation.indexOf("(")));
    const args = [
        config.vault.name,
        config.vault.symbol,
        config.vault.underlying.address,
        String(config.vault.redemptionDelaySeconds),
        config.vault.owner,
        String(config.fees.packageIndex),
    ];
    const data = cast(["calldata", functionSignature(entry), ...args]);

    return {
        schemaVersion: 1,
        status: "planned",
        kind: "vault-creation",
        chainId: config.chainId,
        deploymentId: deployment.id,
        readBlock: { number: input.blockNumber, hash: block.result.hash },
        input: {
            path: relative(repoRoot, input.configPath),
            sha256: configHash(input.configPath),
        },
        transaction: {
            to: checksum(deployment.address),
            from: checksum(config.caller),
            value: "0",
            data,
            operation,
            arguments: {
                assetName: config.vault.name,
                assetSymbol: config.vault.symbol,
                underlyingToken: checksum(config.vault.underlying.address),
                redemptionDelayInSeconds: String(config.vault.redemptionDelaySeconds),
                owner: checksum(config.vault.owner),
                daoFeePackageIndex: String(config.fees.packageIndex),
            },
        },
        expected: {
            implementation,
            factoryVersion: version,
            feePackage: { source: observedSource, index: config.fees.packageIndex, ...observed },
        },
        provider: { variable: providerName },
        warnings: [
            "the plan is valid for the implementation, version and fee package read at the block above; re-plan if any of them changes",
            "this artifact is not signed and not broadcast; the created addresses are not known until the transaction is mined",
        ],
        references: {
            manifest: `deployments/${config.chainId}/factories.json`,
            abi: deployment.interface.abiPath,
            verificationReport: deployment.verification.reportPath,
        },
    };
})().catch((error) => {
    if (!(error instanceof ChainError) && !(error instanceof InputError)) throw error;
    die(error.code, error.message);
});

const artifactError = firstArtifactError(plan, "vault-creation");
if (artifactError) die("INVALID_ARTIFACT", `generated plan does not match its schema: ${artifactError}`);

const serialized = `${JSON.stringify(plan, null, 4)}\n`;
if (input.outPath) {
    writeFileSync(input.outPath, serialized);
    console.log(`vault:plan: wrote ${relative(repoRoot, input.outPath)} (block ${plan.readBlock.number})`);
} else {
    process.stdout.write(serialized);
}

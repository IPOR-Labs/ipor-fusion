#!/usr/bin/env node
// Executes exactly the calldata of a prepared plan on an ephemeral local fork,
// as the caller the plan names.
//
// Usage:
//   node tools/simulate-vault.mjs --plan <plan.json> [--block <number>] [--out <report.json>]
//
// Exit codes: 0 the simulation ran (see status inside the report), 1 refused,
// 2 bad arguments or an unreadable file.
//
// Only the EOA path is supported: a caller that has code on the fork is refused
// rather than approximated. The fork is never repaired to make the run succeed —
// no upgrade, no code replacement, no role grant. The only state this command
// creates is the impersonation and the gas funding of the caller, both local.

import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { relative, resolve } from "node:path";
import { ChainError, cast, checksum, providerUrl, revertDataOf, rpc, rpcRaw } from "./lib/chain.mjs";
import { forkRpc, startFork } from "./lib/fork.mjs";
import { InputError, readJsonOrThrow, repoRoot } from "./lib/vault-config.mjs";
import { decodeRevert, loadErrorMap } from "./lib/revert-decoder.mjs";
import { verifyVaultState } from "./lib/vault-state.mjs";
import { firstArtifactError } from "./lib/artifact-schema.mjs";

// The deployed ABI does not carry the factory's creation event (it is emitted
// from a library), so the signature comes from the repository source and is
// accepted only when the observed topic matches its hash.
const creationEvent =
    "FusionInstanceCreated(uint256,uint256,string,string,uint8,address,string,uint8,address,address,address,address)";
const instanceType =
    "(uint256,uint256,string,string,uint8,address,string,uint8,address,address,address,address,address,address,address,address,address)";
const instanceFields = [
    "index",
    "version",
    "assetName",
    "assetSymbol",
    "assetDecimals",
    "underlyingToken",
    "underlyingTokenSymbol",
    "underlyingTokenDecimals",
    "initialOwner",
    "plasmaVault",
    "plasmaVaultBase",
    "accessManager",
    "feeManager",
    "rewardsManager",
    "withdrawManager",
    "contextManager",
    "priceManager",
];

function die(code, message) {
    console.error(`vault:simulate: ${code}: ${message}`);
    process.exit(code === "INVALID_ARGUMENT" || code.endsWith("_UNREADABLE") ? 2 : 1);
}

function parseArgs(argv) {
    const values = {};
    for (let index = 0; index < argv.length; index += 2) {
        const flag = argv[index];
        const value = argv[index + 1];
        if (!value || !["--plan", "--block", "--out"].includes(flag)) {
            die("INVALID_ARGUMENT", "expected --plan <file> [--block <number>] [--out <file>]");
        }
        if (Object.hasOwn(values, flag)) die("INVALID_ARGUMENT", `duplicate ${flag}`);
        values[flag] = value;
    }
    if (!values["--plan"]) die("INVALID_ARGUMENT", "missing --plan");
    if (values["--block"] !== undefined && !/^[1-9][0-9]*$/.test(values["--block"])) {
        die("INVALID_ARGUMENT", "--block must be a positive integer");
    }
    return {
        planPath: resolve(values["--plan"]),
        blockNumber: values["--block"] ? Number(values["--block"]) : undefined,
        outPath: values["--out"] ? resolve(values["--out"]) : undefined,
    };
}

const input = parseArgs(process.argv.slice(2));
const sha256 = (bytes) => `0x${createHash("sha256").update(bytes).digest("hex")}`;

let plan;
let planHash;
try {
    plan = readJsonOrThrow(input.planPath, "PLAN_UNREADABLE");
    planHash = sha256(readFileSync(input.planPath));
} catch (error) {
    if (!(error instanceof InputError)) throw error;
    die(error.code, error.message);
}
const planError = firstArtifactError(plan, "vault-creation");
if (planError) die("INVALID_PLAN", `${relative(repoRoot, input.planPath)} ${planError}`);

let errorMap = {};
try {
    errorMap = loadErrorMap();
} catch {
    // Without catalog/errors.json a revert is still reported, only not named.
}

const blockNumber = input.blockNumber ?? plan.readBlock?.number;
if (!Number.isInteger(blockNumber)) die("INVALID_PLAN", "the plan has no read block and none was given");

let fork;
const report = await (async () => {
    const { name: providerName, url } = providerUrl(plan.chainId);
    fork = await startFork({ url, blockNumber, chainId: plan.chainId });

    const { from, to, data, value } = plan.transaction;

    const callerCode = await forkRpc(fork.url, "eth_getCode", [from, "latest"]);
    if (callerCode && callerCode !== "0x") {
        throw new ChainError(
            "UNSUPPORTED_EXECUTION_PATH",
            `caller ${from} has code on the fork; only the EOA path is simulated`,
        );
    }

    // The plan is only meaningful against the implementation it was built for.
    const slot = await forkRpc(fork.url, "eth_getStorageAt", [
        to,
        "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc",
        "latest",
    ]);
    const implementation = checksum(`0x${String(slot).slice(-40)}`);
    if (implementation.toLowerCase() !== plan.expected.implementation.toLowerCase()) {
        throw new ChainError(
            "IMPLEMENTATION_MISMATCH",
            `the plan expects ${plan.expected.implementation}, the fork has ${implementation}`,
        );
    }

    const block = await forkRpc(fork.url, "eth_getBlockByNumber", [`0x${blockNumber.toString(16)}`, false]);

    // The return value is read first, from the same state, because a receipt
    // does not carry it. It is a prediction until the logs confirm it.
    const predicted = await rpcRaw(fork.url, "eth_call", [{ from, to, data, value: "0x0" }, "latest"]);

    await forkRpc(fork.url, "anvil_impersonateAccount", [from], "IMPERSONATION_FAILED");
    // Explicit, fork-only funding: the caller pays gas in the simulation.
    await forkRpc(fork.url, "anvil_setBalance", [from, "0xde0b6b3a7640000"], "IMPERSONATION_FAILED");

    const txHash = await forkRpc(
        fork.url,
        "eth_sendTransaction",
        [{ from, to, data, value: "0x0" }],
        "SIMULATION_FAILED",
    );
    let receipt = null;
    for (let attempt = 0; attempt < 40 && receipt === null; attempt += 1) {
        receipt = await forkRpc(fork.url, "eth_getTransactionReceipt", [txHash], "SIMULATION_FAILED");
        if (receipt === null) await new Promise((wait) => setTimeout(wait, 100));
    }
    if (receipt === null) throw new ChainError("SIMULATION_FAILED", "the fork returned no receipt for the sent call");
    const succeeded = receipt.status === "0x1";

    let created = null;
    let creationLog = null;
    if (succeeded) {
        const topic = cast(["keccak", creationEvent]);
        const logs = receipt.logs.filter(
            (log) => log.address.toLowerCase() === to.toLowerCase() && log.topics[0] === topic,
        );
        if (logs.length === 1) {
            const decoded = JSON.parse(cast(["decode-event", "--sig", creationEvent, logs[0].data, "--json"]));
            creationLog = {
                signature: creationEvent,
                topic,
                emitter: checksum(logs[0].address),
                index: String(decoded[0]),
                version: String(decoded[1]),
                initialOwner: checksum(decoded[8]),
                plasmaVault: checksum(decoded[9]),
                plasmaVaultBase: checksum(decoded[10]),
                feeManager: checksum(decoded[11]),
            };
        }
        if (!predicted.error && typeof predicted.result === "string") {
            const values = JSON.parse(cast(["decode-abi", "--json", `f()(${instanceType})`, predicted.result]));
            created = Object.fromEntries(
                instanceFields.map((field, position) => [
                    field,
                    /^0x[0-9a-fA-F]{40}$/.test(String(values[0][position]))
                        ? checksum(String(values[0][position]))
                        : String(values[0][position]),
                ]),
            );
        }
    }

    // A prediction that the emitted event contradicts is not reported as fact.
    if (created && creationLog && created.plasmaVault.toLowerCase() !== creationLog.plasmaVault.toLowerCase()) {
        throw new ChainError(
            "SIMULATION_INCONSISTENT",
            `eth_call predicted vault ${created.plasmaVault}, the emitted event names ${creationLog.plasmaVault}`,
        );
    }

    // Existence of the addresses proves nothing on its own, so the created
    // state is verified against the input and against the chain itself.
    let verification = null;
    if (created) {
        verification = await verifyVaultState(
            fork.url,
            created,
            {
                name: plan.transaction.arguments.assetName,
                symbol: plan.transaction.arguments.assetSymbol,
                underlying: plan.transaction.arguments.underlyingToken,
                underlyingDecimals: created.underlyingTokenDecimals,
                redemptionDelaySeconds: plan.transaction.arguments.redemptionDelayInSeconds,
                managementFeeBps: plan.expected.feePackage.managementFeeBps,
                performanceFeeBps: plan.expected.feePackage.performanceFeeBps,
                feeRecipient: plan.expected.feePackage.feeRecipient,
            },
            to,
        );
    }

    // A reverted call is named through the repository's error map (catalog/errors.json);
    // an unknown selector or empty data is reported as such, never guessed.
    let revert = null;
    if (!succeeded) {
        const revertData = predicted.error ? revertDataOf(predicted.error) : null;
        revert = {
            data: revertData,
            ...decodeRevert(revertData ?? "0x", errorMap),
            note: predicted.error
                ? null
                : "eth_call succeeded but the sent transaction reverted; the state changed between the two or the fork rejected the transaction",
        };
    }

    return {
        schemaVersion: 1,
        status: !succeeded ? "reverted" : verification && !verification.ok ? "unverified" : "success",
        kind: "vault-creation-simulation",
        chainId: plan.chainId,
        deploymentId: plan.deploymentId,
        fork: {
            engine: "anvil",
            blockNumber,
            blockHash: block.hash,
            broadcast: false,
        },
        plan: {
            path: relative(repoRoot, input.planPath),
            sha256: planHash,
            inputSha256: plan.input?.sha256 ?? null,
        },
        transaction: { to: checksum(to), from: checksum(from), value: value ?? "0", localHash: txHash },
        result: {
            succeeded,
            gasUsed: Number.parseInt(receipt.gasUsed, 16),
            logCount: receipt.logs.length,
            revertReason: revert,
            created,
            creationEvent: creationLog,
            verification: verification
                ? { ok: verification.ok, checks: verification.checks, readings: verification.readings }
                : null,
        },
        provider: { variable: providerName },
        warnings: [
            "the created addresses exist only in this ephemeral fork; a real transaction produces different ones",
            "the fork was not repaired: no upgrade, no code replacement and no role was granted to make the run succeed",
            "the caller was impersonated and funded on the fork only, to pay simulated gas",
        ],
        references: { manifest: plan.references?.manifest ?? null, abi: plan.references?.abi ?? null },
    };
})().catch((error) => {
    if (!(error instanceof ChainError) && !(error instanceof InputError)) throw error;
    fork?.stop();
    die(error.code, error.message);
});

fork?.stop();

const artifactError = firstArtifactError(report, "vault-creation-simulation");
if (artifactError) die("INVALID_ARTIFACT", `generated simulation does not match its schema: ${artifactError}`);

const serialized = `${JSON.stringify(report, null, 4)}\n`;
if (input.outPath) {
    writeFileSync(input.outPath, serialized);
    console.log(
        `vault:simulate: ${report.status} (gas ${report.result.gasUsed}), wrote ${relative(repoRoot, input.outPath)}`,
    );
} else {
    process.stdout.write(serialized);
}
process.exit(0);

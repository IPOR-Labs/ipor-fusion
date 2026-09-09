#!/usr/bin/env node
// Exports a plan as a Safe Transaction Builder batch and simulates the Safe as
// the factory's direct caller.
//
// Usage:
//   node tools/export-safe-plan.mjs --plan <plan.json> [--compare-with <address>]
//                                   [--block <number>] [--out <batch.json>] [--json]
//
// Exit codes: 0 exported (and simulated), 1 refused or the simulation reverted,
// 2 bad arguments.
//
// Nothing is published: the batch is a file for the Safe UI. No wrapper contract
// is deployed — the Safe calls the factory directly, which is exactly why its
// fee package must be checked for the Safe's own address.

import { writeFileSync } from "node:fs";
import { relative, resolve } from "node:path";
import { ChainError, callAt, cast, checksum, providerUrl, rpc } from "./lib/chain.mjs";
import { startFork } from "./lib/fork.mjs";
import { InputError, readJsonOrThrow, manifestPathFor, repoRoot } from "./lib/vault-config.mjs";
import { compareFeeResolution, safeBatch } from "./lib/safe-plan.mjs";

function die(code, message) {
    console.error(`vault:safe: ${code}: ${message}`);
    process.exit(code === "INVALID_ARGUMENT" || code.endsWith("_UNREADABLE") ? 2 : 1);
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
        if (!value || !["--plan", "--compare-with", "--block", "--out"].includes(flag)) {
            die("INVALID_ARGUMENT", "expected --plan <file> [--compare-with <address>] [--block <n>] [--out <file>] [--json]");
        }
        values[flag] = value;
    }
    if (!values["--plan"]) die("INVALID_ARGUMENT", "missing --plan");
    if (values["--compare-with"] && !/^0x[0-9a-fA-F]{40}$/.test(values["--compare-with"])) {
        die("INVALID_ARGUMENT", "--compare-with must be a 20-byte address");
    }
    if (values["--block"] && !/^[1-9][0-9]*$/.test(values["--block"])) {
        die("INVALID_ARGUMENT", "--block must be a positive integer");
    }
    return values;
}

const args = parseArgs(process.argv.slice(2));
const planPath = resolve(args["--plan"]);
const plan = readJsonOrThrow(planPath, "PLAN_UNREADABLE");
if (plan.kind !== "vault-creation" || plan.status !== "planned") {
    die("INVALID_PLAN", `${relative(repoRoot, planPath)} is not a planned vault creation`);
}

let fork;
const report = await (async () => {
    const manifest = readJsonOrThrow(manifestPathFor(plan.chainId), "MANIFEST_UNREADABLE");
    const deployment = manifest.deployments.find((entry) => entry.id === plan.deploymentId);
    if (!deployment) throw new ChainError("UNKNOWN_DEPLOYMENT", `${plan.deploymentId} is not registered`);
    const abi = readJsonOrThrow(resolve(repoRoot, deployment.interface.abiPath), "ABI_UNREADABLE");

    const { name: providerName, url } = providerUrl(plan.chainId);
    const blockNumber = args["--block"] ? Number(args["--block"]) : plan.readBlock.number;
    const blockTag = `0x${blockNumber.toString(16)}`;

    const safe = checksum(plan.transaction.from);
    const code = await rpc(url, "eth_getCode", [safe, blockTag]);
    if (code.error) throw new ChainError("RPC_UNAVAILABLE", `${providerName} did not answer`);
    if (!code.result || code.result === "0x") {
        throw new ChainError(
            "CALLER_NOT_A_CONTRACT",
            `${safe} has no code at block ${blockNumber}; a Safe export needs a plan whose caller is the Safe`,
        );
    }

    const resolveFees = async (caller) => {
        const at = { to: deployment.address, from: caller, blockTag };
        const [clientPackages, isCustom] = await callAt(url, at, abi, "getBusinessClientFeePackages", [caller]);
        const [globalPackages] = await callAt(url, at, abi, "getDaoFeePackages");
        const packages = isCustom ? clientPackages : globalPackages;
        const index = plan.expected.feePackage.index;
        if (index >= packages.length) {
            throw new ChainError(
                "FEE_PACKAGE_MISMATCH",
                `package index ${index} does not exist for ${caller} (${packages.length} package(s))`,
            );
        }
        const [management, performance, recipient] = packages[index];
        return {
            caller: checksum(caller),
            source: isCustom ? "business-client" : "dao-global",
            index,
            managementFeeBps: Number(management),
            performanceFeeBps: Number(performance),
            feeRecipient: checksum(recipient),
        };
    };

    const safeFees = await resolveFees(safe);
    const planned = plan.expected.feePackage;
    const matchesPlan =
        safeFees.source === planned.source &&
        safeFees.managementFeeBps === planned.managementFeeBps &&
        safeFees.performanceFeeBps === planned.performanceFeeBps &&
        safeFees.feeRecipient.toLowerCase() === planned.feeRecipient.toLowerCase();
    if (!matchesPlan) {
        throw new ChainError(
            "FEE_PACKAGE_MISMATCH",
            `the Safe resolves ${safeFees.source} ${safeFees.managementFeeBps}/${safeFees.performanceFeeBps} to ${safeFees.feeRecipient}, the plan expects ${planned.source} ${planned.managementFeeBps}/${planned.performanceFeeBps} to ${planned.feeRecipient}`,
        );
    }

    // The factory selects fees by msg.sender, so the Safe's resolution is
    // compared against another caller — normally the owner EOA.
    const comparison = args["--compare-with"]
        ? { with: checksum(args["--compare-with"]), ...compareFeeResolution(safeFees, await resolveFees(args["--compare-with"])) }
        : null;

    // Simulate the Safe as the direct caller: msg.sender is the Safe itself.
    fork = await startFork({ url, blockNumber, chainId: plan.chainId });
    await rpc(fork.url, "anvil_impersonateAccount", [safe]);
    await rpc(fork.url, "anvil_setBalance", [safe, "0xde0b6b3a7640000"]);
    const hash = (
        await rpc(fork.url, "eth_sendTransaction", [
            { from: safe, to: plan.transaction.to, data: plan.transaction.data, value: "0x0" },
        ])
    ).result;
    let receipt = null;
    for (let attempt = 0; attempt < 40 && receipt === null; attempt += 1) {
        receipt = (await rpc(fork.url, "eth_getTransactionReceipt", [hash])).result;
        if (receipt === null) await new Promise((wait) => setTimeout(wait, 100));
    }
    if (receipt === null) throw new ChainError("SIMULATION_FAILED", "the fork returned no receipt");

    const createdAt = Date.now();
    const batch = safeBatch({
        chainId: plan.chainId,
        safe,
        to: plan.transaction.to,
        value: plan.transaction.value,
        data: plan.transaction.data,
        name: `Create Fusion vault (${plan.deploymentId})`,
        description: `Calldata from ${relative(repoRoot, planPath)} (sha256 ${plan.input.sha256}), planned at block ${plan.readBlock.number}.`,
        createdAt,
    });

    if (args["--out"]) writeFileSync(resolve(args["--out"]), `${JSON.stringify(batch, null, 4)}\n`);

    return {
        schemaVersion: 1,
        status: receipt.status === "0x1" ? "exported" : "reverted",
        kind: "vault-creation-safe-export",
        chainId: plan.chainId,
        deploymentId: plan.deploymentId,
        safe,
        readBlock: blockNumber,
        fees: { safe: safeFees, comparedWith: comparison },
        simulation: {
            callerIsTheSafe: true,
            succeeded: receipt.status === "0x1",
            gasUsed: Number.parseInt(receipt.gasUsed, 16),
            broadcast: false,
        },
        batch: args["--out"] ? { path: relative(repoRoot, resolve(args["--out"])) } : { inline: batch },
        provider: { variable: providerName },
        warnings: [
            "the simulation impersonates the Safe address, so msg.sender is the Safe; it does not run the Safe's own signature threshold or execTransaction logic",
            "the batch is a file for the Safe Transaction Builder; nothing was proposed or published to any service",
            "no wrapper contract is involved: any wrapper would change msg.sender again and resolve different fees",
        ],
    };
})().catch((error) => {
    fork?.stop();
    if (!(error instanceof ChainError) && !(error instanceof InputError)) throw error;
    die(error.code, error.message);
});

fork?.stop();

if (args["--json"]) {
    process.stdout.write(`${JSON.stringify(report, null, 4)}\n`);
} else {
    console.log(`vault:safe: ${report.status} for ${report.safe} at block ${report.readBlock}`);
    console.log(`  fees ${report.fees.safe.source} ${report.fees.safe.managementFeeBps}/${report.fees.safe.performanceFeeBps} -> ${report.fees.safe.feeRecipient}`);
    if (report.fees.comparedWith) {
        console.log(
            report.fees.comparedWith.differs
                ? `  DIFFERS from ${report.fees.comparedWith.with}: ${report.fees.comparedWith.differences.map((d) => d.field).join(", ")}`
                : `  same resolution as ${report.fees.comparedWith.with}`,
        );
    }
    console.log(`  simulation as the Safe: ${report.simulation.succeeded ? "success" : "reverted"} (gas ${report.simulation.gasUsed})`);
    if (report.batch.path) console.log(`  batch written to ${report.batch.path}`);
}
process.exit(report.status === "exported" ? 0 : 1);

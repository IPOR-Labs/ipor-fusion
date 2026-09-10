#!/usr/bin/env node
// Revalidates a prepared plan against the chain as it is now, and re-simulates
// it at that state. Still no signer, still no broadcast.
//
// Usage:
//   node tools/preflight-plan.mjs --plan <plan.json> [--block <number>]
//                                 [--max-age-blocks <n>] [--skip-simulation] [--json]
//
// Exit codes: 0 the plan is still valid ("go"), 1 the plan is invalidated
// ("stop") or the preflight could not complete, 2 bad arguments.
//
// A "go" is a statement about the state that was read, not a guarantee about the
// state the transaction will be included in — see the residual risk in the report.

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { relative, resolve } from "node:path";
import { ChainError, callAt, checksum, providerUrl, rpc } from "./lib/chain.mjs";
import { configHash, InputError, manifestPathFor, readJsonOrThrow, repoRoot } from "./lib/vault-config.mjs";
import { firstArtifactError } from "./lib/artifact-schema.mjs";

function die(code, message) {
    console.error(`vault:preflight: ${code}: ${message}`);
    process.exit(code === "INVALID_ARGUMENT" || code.endsWith("_UNREADABLE") ? 2 : 1);
}

function parseArgs(argv) {
    const values = {};
    const rest = [];
    for (const arg of argv) {
        if (arg === "--json" || arg === "--skip-simulation") values[arg] = true;
        else rest.push(arg);
    }
    for (let index = 0; index < rest.length; index += 2) {
        const flag = rest[index];
        const value = rest[index + 1];
        if (!value || !["--plan", "--block", "--max-age-blocks"].includes(flag)) {
            die("INVALID_ARGUMENT", "expected --plan <file> [--block <number>] [--max-age-blocks <n>] [--skip-simulation] [--json]");
        }
        if (Object.hasOwn(values, flag)) die("INVALID_ARGUMENT", `duplicate ${flag}`);
        values[flag] = value;
    }
    if (!values["--plan"]) die("INVALID_ARGUMENT", "missing --plan");
    for (const numeric of ["--block", "--max-age-blocks"]) {
        if (values[numeric] !== undefined && !/^[0-9]+$/.test(values[numeric])) {
            die("INVALID_ARGUMENT", `${numeric} must be a non-negative integer`);
        }
    }
    return {
        planPath: resolve(values["--plan"]),
        block: values["--block"] ? Number(values["--block"]) : undefined,
        maxAgeBlocks: values["--max-age-blocks"] ? Number(values["--max-age-blocks"]) : undefined,
        skipSimulation: values["--skip-simulation"] === true,
        asJson: values["--json"] === true,
    };
}

const input = parseArgs(process.argv.slice(2));
const plan = readJsonOrThrow(input.planPath, "PLAN_UNREADABLE");
const planError = firstArtifactError(plan, "vault-creation");
if (planError) die("INVALID_PLAN", `${relative(repoRoot, input.planPath)} ${planError}`);

const report = await (async () => {
    const checks = [];
    const record = (id, description, ok, observed, expected) =>
        checks.push({ id, description, ok, observed: String(observed), expected: String(expected) });

    // The plan must still describe the input it was built from.
    const configPath = resolve(repoRoot, plan.input.path);
    record(
        "input.unchanged",
        "the configuration file still hashes to what the plan recorded",
        existsSync(configPath) && configHash(configPath) === plan.input.sha256,
        existsSync(configPath) ? configHash(configPath) : "missing",
        plan.input.sha256,
    );

    const manifest = readJsonOrThrow(manifestPathFor(plan.chainId), "MANIFEST_UNREADABLE");
    const deployment = manifest.deployments.find((entry) => entry.id === plan.deploymentId);
    if (!deployment) throw new ChainError("UNKNOWN_DEPLOYMENT", `${plan.deploymentId} is no longer registered`);
    record(
        "manifest.verified",
        "the deployment is still verified in the registry",
        deployment.status === "verified",
        deployment.status,
        "verified",
    );

    const { name: providerName, url } = providerUrl(plan.chainId);
    const chain = await rpc(url, "eth_chainId", []);
    if (chain.error) throw new ChainError("RPC_UNAVAILABLE", `${providerName} did not answer`);
    const observedChain = Number.parseInt(chain.result, 16);
    record("chain.id", "the provider still serves the plan's chain", observedChain === plan.chainId, observedChain, plan.chainId);
    if (observedChain !== plan.chainId) throw new ChainError("CHAIN_MISMATCH", `provider reports chain ${observedChain}`);

    const head = Number.parseInt((await rpc(url, "eth_blockNumber", [])).result, 16);
    const blockNumber = input.block ?? head;
    const blockTag = `0x${blockNumber.toString(16)}`;
    const block = await rpc(url, "eth_getBlockByNumber", [blockTag, false]);
    if (block.error || !block.result?.hash) {
        throw new ChainError("HISTORICAL_STATE_UNAVAILABLE", `block ${blockNumber} is unavailable`);
    }

    if (input.maxAgeBlocks !== undefined) {
        const age = blockNumber - plan.readBlock.number;
        record(
            "plan.age",
            "the plan was built recently enough",
            age <= input.maxAgeBlocks,
            `${age} block(s)`,
            `at most ${input.maxAgeBlocks}`,
        );
    }

    const storage = await rpc(url, "eth_getStorageAt", [deployment.address, deployment.proxy.implementationSlot, blockTag]);
    if (storage.error) throw new ChainError("RPC_UNAVAILABLE", "the implementation slot could not be read");
    const implementation = checksum(`0x${storage.result.slice(-40)}`);
    record(
        "identity.implementation",
        "the proxy still points at the implementation the plan was built for",
        implementation.toLowerCase() === plan.expected.implementation.toLowerCase(),
        implementation,
        plan.expected.implementation,
    );

    const abi = readJsonOrThrow(resolve(repoRoot, deployment.interface.abiPath), "ABI_UNREADABLE");
    const at = { to: deployment.address, from: plan.transaction.from, blockTag };

    const version = String((await callAt(url, at, abi, "getFusionFactoryVersion"))[0]);
    record(
        "identity.version",
        "the factory still reports the planned version",
        version === plan.expected.factoryVersion,
        version,
        plan.expected.factoryVersion,
    );

    // Components: the verification report named them; a swap changes what the
    // creation will produce even though the factory's identity is unchanged.
    const reportPath = deployment.verification.reportPath;
    if (reportPath && existsSync(resolve(repoRoot, reportPath))) {
        const verification = readJsonOrThrow(resolve(repoRoot, reportPath), "REPORT_UNREADABLE");
        const factories = (await callAt(url, at, abi, "getFactoryAddresses"))[0].map((address) => checksum(address));
        const bases = (await callAt(url, at, abi, "getBaseAddresses"))[0].map((address) => checksum(address));
        const observed = new Set([...factories, ...bases].map((address) => address.toLowerCase()));
        const recorded = (verification.reads?.components?.entries ?? [])
            .filter((entry) => entry.kind === "factory" || entry.kind === "base")
            .map((entry) => entry.address.toLowerCase());
        const missing = recorded.filter((address) => !observed.has(address));
        record(
            "identity.components",
            "the factory still uses the component addresses the verification report recorded",
            recorded.length > 0 && missing.length === 0,
            missing.length === 0 ? `${recorded.length} unchanged` : `changed: ${missing.join(", ")}`,
            `${recorded.length} unchanged`,
        );
    }

    const callerCode = await rpc(url, "eth_getCode", [plan.transaction.from, blockTag]);
    record(
        "caller.shape",
        "the caller is still an account without code, as the simulated path assumes",
        callerCode.result === "0x",
        callerCode.result === "0x" ? "no code" : "has code",
        "no code",
    );

    const [clientPackages, isCustom] = await callAt(url, at, abi, "getBusinessClientFeePackages", [plan.transaction.from]);
    const [globalPackages] = await callAt(url, at, abi, "getDaoFeePackages");
    const source = isCustom ? "business-client" : "dao-global";
    record(
        "fees.source",
        "the caller still resolves to the same package list",
        source === plan.expected.feePackage.source,
        source,
        plan.expected.feePackage.source,
    );
    const packages = isCustom ? clientPackages : globalPackages;
    const index = plan.expected.feePackage.index;
    if (index < packages.length) {
        const [management, performance, recipient] = packages[index];
        record(
            "fees.values",
            "the selected package still charges the planned fees",
            Number(management) === plan.expected.feePackage.managementFeeBps &&
                Number(performance) === plan.expected.feePackage.performanceFeeBps,
            `${management}/${performance}`,
            `${plan.expected.feePackage.managementFeeBps}/${plan.expected.feePackage.performanceFeeBps}`,
        );
        record(
            "fees.recipient",
            "the selected package still pays the planned recipient",
            checksum(recipient).toLowerCase() === plan.expected.feePackage.feeRecipient.toLowerCase(),
            checksum(recipient),
            plan.expected.feePackage.feeRecipient,
        );
    } else {
        record("fees.index", "the planned package index still exists", false, `${packages.length} package(s)`, `index ${index}`);
    }

    const stopped = checks.filter((check) => !check.ok);
    let simulation = null;
    if (stopped.length === 0 && !input.skipSimulation) {
        // Re-simulate at the state just read, not at the state the plan was built on.
        const result = spawnSync(
            process.execPath,
            [resolve(repoRoot, "tools/simulate-vault.mjs"), "--plan", input.planPath, "--block", String(blockNumber)],
            { cwd: repoRoot, encoding: "utf8" },
        );
        if (result.status !== 0) {
            throw new ChainError("SIMULATION_FAILED", `re-simulation at block ${blockNumber} did not run: ${result.stderr.trim()}`);
        }
        const parsed = JSON.parse(result.stdout);
        simulation = {
            status: parsed.status,
            blockNumber: parsed.fork.blockNumber,
            gasUsed: parsed.result.gasUsed,
            verified: parsed.result.verification?.ok ?? null,
        };
        record(
            "simulation.current",
            "the plan still succeeds and verifies when simulated at the current state",
            parsed.status === "success",
            parsed.status,
            "success",
        );
    }

    const failed = checks.filter((check) => !check.ok);
    return {
        schemaVersion: 1,
        status: failed.length === 0 ? "go" : "stop",
        kind: "vault-creation-preflight",
        chainId: plan.chainId,
        deploymentId: plan.deploymentId,
        plan: { path: relative(repoRoot, input.planPath), builtAtBlock: plan.readBlock.number },
        readAt: { blockNumber, blockHash: block.result.hash, head },
        checks,
        simulation,
        provider: { variable: providerName },
        residualRisk: [
            "state can change between this preflight and the block the transaction is included in; the factory does not let a caller require an implementation, version or fee package atomically",
            "a go is about the state read at the block above, not a guarantee about execution",
            "an execution path that changes msg.sender (a Safe or a helper contract) resolves different fee packages and needs its own preflight",
        ],
    };
})().catch((error) => {
    if (!(error instanceof ChainError) && !(error instanceof InputError)) throw error;
    die(error.code, error.message);
});

const artifactError = firstArtifactError(report, "vault-creation-preflight");
if (artifactError) die("INVALID_ARTIFACT", `generated preflight does not match its schema: ${artifactError}`);

if (input.asJson) {
    process.stdout.write(`${JSON.stringify(report, null, 4)}\n`);
} else {
    console.log(`vault:preflight: ${report.status} (read at block ${report.readAt.blockNumber})`);
    for (const check of report.checks) {
        console.log(`  ${check.ok ? "ok  " : "STOP"} ${check.id.padEnd(24)} ${check.ok ? "" : `observed ${check.observed}, expected ${check.expected}`}`);
    }
}
process.exit(report.status === "go" ? 0 : 1);

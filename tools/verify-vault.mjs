#!/usr/bin/env node
// Resolves what a creation transaction actually produced, from its receipt.
//
// Usage:
//   node tools/verify-vault.mjs --chain <id> --tx <hash> [--rpc-url <url>]
//                               [--min-confirmations <n>] [--config <input.json>] [--json]
//
// Exit codes: 0 resolved (read `status` in the report), 1 refused or not
// resolvable, 2 bad arguments.
//
// The return value of a Solidity call is not available in a receipt, so nothing
// here relies on one: addresses come from the factory's own event, filtered by
// emitter, and are then completed with state reads.

import { relative, resolve } from "node:path";
import { ChainError, cast, checksum, providerUrl, rpc } from "./lib/chain.mjs";
import { selectCreationLog } from "./lib/creation-log.mjs";
import { InputError, checkVaultConfig, manifestPathFor, readJsonOrThrow, repoRoot } from "./lib/vault-config.mjs";
import { readVaultState, checkVaultState } from "./lib/vault-state.mjs";

const creationEvent =
    "FusionInstanceCreated(uint256,uint256,string,string,uint8,address,string,uint8,address,address,address,address)";

function die(code, message) {
    console.error(`vault:verify: ${code}: ${message}`);
    process.exit(code === "INVALID_ARGUMENT" || code.endsWith("_UNREADABLE") ? 2 : 1);
}

function parseArgs(argv) {
    const values = {};
    const flags = ["--chain", "--tx", "--rpc-url", "--min-confirmations", "--config"];
    const rest = [];
    for (let index = 0; index < argv.length; index += 1) {
        if (argv[index] === "--json") {
            values["--json"] = true;
            continue;
        }
        rest.push(argv[index]);
    }
    for (let index = 0; index < rest.length; index += 2) {
        const flag = rest[index];
        const value = rest[index + 1];
        if (!value || !flags.includes(flag)) {
            die("INVALID_ARGUMENT", "expected --chain <id> --tx <hash> [--rpc-url <url>] [--min-confirmations <n>] [--config <file>] [--json]");
        }
        if (Object.hasOwn(values, flag)) die("INVALID_ARGUMENT", `duplicate ${flag}`);
        values[flag] = value;
    }
    for (const flag of ["--chain", "--tx"]) {
        if (!values[flag]) die("INVALID_ARGUMENT", `missing ${flag}`);
    }
    if (!/^[1-9][0-9]*$/.test(values["--chain"])) die("INVALID_ARGUMENT", "--chain must be a positive integer");
    if (!/^0x[0-9a-fA-F]{64}$/.test(values["--tx"])) die("INVALID_ARGUMENT", "--tx must be a 32-byte hash");
    if (values["--min-confirmations"] !== undefined && !/^[0-9]+$/.test(values["--min-confirmations"])) {
        die("INVALID_ARGUMENT", "--min-confirmations must be a non-negative integer");
    }
    return {
        chainId: Number(values["--chain"]),
        txHash: values["--tx"],
        rpcOverride: values["--rpc-url"],
        minConfirmations: values["--min-confirmations"] === undefined ? 1 : Number(values["--min-confirmations"]),
        configPath: values["--config"] ? resolve(values["--config"]) : undefined,
        asJson: values["--json"] === true,
    };
}

const input = parseArgs(process.argv.slice(2));

const report = await (async () => {
    const manifestPath = manifestPathFor(input.chainId);
    const manifest = readJsonOrThrow(manifestPath, "MANIFEST_UNREADABLE");

    let config = null;
    if (input.configPath) {
        config = readJsonOrThrow(input.configPath, "CONFIG_UNREADABLE");
        const { findings } = checkVaultConfig(config);
        if (findings.length > 0) {
            const first = findings[0];
            throw new InputError(first.code, `${relative(repoRoot, input.configPath)} ${first.where}: ${first.message}`);
        }
    }

    // An explicit endpoint (a local fork, for instance) replaces the catalog's
    // provider; either way only the variable name or the word "override" is reported.
    const provider = input.rpcOverride
        ? { name: "--rpc-url override", url: input.rpcOverride }
        : providerUrl(input.chainId);

    const chain = await rpc(provider.url, "eth_chainId", []);
    if (chain.error || typeof chain.result !== "string") {
        throw new ChainError("RPC_UNAVAILABLE", `${provider.name} did not answer`);
    }
    const observedChain = Number.parseInt(chain.result, 16);
    if (observedChain !== input.chainId) {
        throw new ChainError("CHAIN_MISMATCH", `requested chain ${input.chainId}, endpoint reports ${observedChain}`);
    }

    const transaction = (await rpc(provider.url, "eth_getTransactionByHash", [input.txHash])).result;
    if (!transaction) {
        throw new ChainError("TRANSACTION_UNKNOWN", `the endpoint does not know ${input.txHash}`);
    }
    if (transaction.blockNumber === null) {
        return {
            schemaVersion: 1,
            status: "pending",
            kind: "vault-creation-receipt",
            chainId: input.chainId,
            transaction: { hash: input.txHash, to: transaction.to ? checksum(transaction.to) : null },
            warnings: ["the transaction is known but not yet in a block; do not resend the creation"],
        };
    }

    const receipt = (await rpc(provider.url, "eth_getTransactionReceipt", [input.txHash])).result;
    if (!receipt) throw new ChainError("RECEIPT_UNAVAILABLE", "the transaction is mined but has no receipt yet");

    const latest = Number.parseInt((await rpc(provider.url, "eth_blockNumber", [])).result, 16);
    const blockNumber = Number.parseInt(receipt.blockNumber, 16);
    const confirmations = latest - blockNumber + 1;

    const deployment = manifest.deployments?.find(
        (entry) => entry.address.toLowerCase() === String(receipt.to).toLowerCase(),
    );

    const base = {
        schemaVersion: 1,
        kind: "vault-creation-receipt",
        chainId: input.chainId,
        deploymentId: deployment?.id ?? null,
        transaction: {
            hash: input.txHash,
            to: receipt.to ? checksum(receipt.to) : null,
            from: checksum(receipt.from),
            blockNumber,
            blockHash: receipt.blockHash,
            gasUsed: Number.parseInt(receipt.gasUsed, 16),
            confirmations,
        },
        provider: { source: input.rpcOverride ? "override" : provider.name },
    };

    if (receipt.status !== "0x1") {
        return {
            ...base,
            status: "reverted",
            warnings: ["the creation reverted; no vault exists and the transaction must not be retried blindly"],
        };
    }
    if (confirmations < input.minConfirmations) {
        return {
            ...base,
            status: "not-final",
            warnings: [
                `the receipt has ${confirmations} confirmation(s), fewer than the required ${input.minConfirmations}; a reorg can still change this result`,
            ],
        };
    }
    if (!deployment) {
        throw new ChainError(
            "UNKNOWN_DEPLOYMENT",
            `the transaction targets ${receipt.to}, which chain ${input.chainId} does not register`,
        );
    }

    const topic = cast(["keccak", creationEvent]);
    const selection = selectCreationLog(receipt.logs, deployment.address, topic);
    if (selection.status === "absent") {
        throw new ChainError("CREATION_EVENT_ABSENT", "the receipt carries no creation event from the registered factory");
    }
    if (selection.status === "ambiguous") {
        throw new ChainError("CREATION_EVENT_AMBIGUOUS", `the receipt carries ${selection.count} creation events from the factory`);
    }
    if (selection.status === "foreign-only") {
        throw new ChainError(
            "FOREIGN_CREATION_EVENT",
            `the only matching event was emitted by ${selection.foreign[0].address}, not by the registered factory`,
        );
    }

    const decoded = JSON.parse(cast(["decode-event", "--sig", creationEvent, selection.log.data, "--json"]));
    const plasmaVault = checksum(decoded[9]);
    const one = (address, signature) => cast(["call", "--rpc-url", provider.url, address, signature]).trim();

    // Completed from state, because the event carries only part of the instance.
    const instance = {
        index: String(decoded[0]),
        version: String(decoded[1]),
        assetName: String(decoded[2]).replace(/^"|"$/g, ""),
        assetSymbol: String(decoded[3]).replace(/^"|"$/g, ""),
        assetDecimals: String(decoded[4]),
        underlyingToken: checksum(decoded[5]),
        underlyingTokenSymbol: String(decoded[6]).replace(/^"|"$/g, ""),
        underlyingTokenDecimals: String(decoded[7]),
        initialOwner: checksum(decoded[8]),
        plasmaVault,
        plasmaVaultBase: checksum(decoded[10]),
        feeManager: checksum(decoded[11]),
        accessManager: checksum(one(plasmaVault, "getAccessManagerAddress()(address)")),
        priceManager: checksum(one(plasmaVault, "getPriceOracleMiddleware()(address)")),
        rewardsManager: checksum(one(plasmaVault, "getRewardsClaimManagerAddress()(address)")),
    };

    // The deployed interface exposes no getter for these two, so they are looked
    // for among the receipt's own emitters and stay unresolved if not found.
    const emitters = [...new Set(receipt.logs.map((log) => checksum(log.address)))];
    for (const candidate of emitters) {
        if (candidate.toLowerCase() === plasmaVault.toLowerCase()) continue;
        try {
            const owner = cast(["call", "--rpc-url", provider.url, candidate, "getPlasmaVaultAddress()(address)"]).trim();
            if (owner.toLowerCase() === plasmaVault.toLowerCase()) {
                instance.withdrawManager = candidate;
                break;
            }
        } catch {
            // Not a withdraw manager; the next emitter is tried.
        }
    }

    let verification = null;
    if (config) {
        const readings = await readVaultState(provider.url, instance, deployment.address);
        verification = checkVaultState(readings, {
            name: config.vault.name,
            symbol: config.vault.symbol,
            underlying: config.vault.underlying.address,
            underlyingDecimals: String(config.vault.underlying.decimals),
            redemptionDelaySeconds: String(config.vault.redemptionDelaySeconds),
            managementFeeBps: config.fees.expected.managementFeeBps,
            performanceFeeBps: config.fees.expected.performanceFeeBps,
            feeRecipient: config.fees.expected.feeRecipient,
        }, instance);
    }

    return {
        ...base,
        status: verification && !verification.ok ? "unverified" : "success",
        result: {
            instance,
            unresolved: verification?.unresolved ?? ["withdrawManager", "contextManager"].filter((key) => !instance[key]),
            foreignEventsIgnored: selection.foreign.length,
            verification: verification ? { ok: verification.ok, checks: verification.checks } : null,
        },
        warnings: [
            "addresses come from the factory's own event and from state reads, not from a Solidity return value",
            "the deployed interface exposes no getter for the context manager, so it is reported as unresolved rather than guessed",
        ],
    };
})().catch((error) => {
    if (!(error instanceof ChainError) && !(error instanceof InputError)) throw error;
    die(error.code, error.message);
});

if (input.asJson) {
    process.stdout.write(`${JSON.stringify(report, null, 4)}\n`);
} else {
    console.log(`vault:verify: ${report.status}`);
    if (report.result) {
        console.log(`  vault      ${report.result.instance.plasmaVault}`);
        console.log(`  owner      ${report.result.instance.initialOwner}`);
        console.log(`  underlying ${report.result.instance.underlyingToken} (${report.result.instance.underlyingTokenSymbol})`);
        console.log(`  unresolved ${report.result.unresolved.join(", ") || "none"}`);
        if (report.result.verification) {
            const failed = report.result.verification.checks.filter((check) => !check.ok);
            console.log(`  checks     ${report.result.verification.checks.length - failed.length}/${report.result.verification.checks.length} passed`);
            for (const check of failed) console.log(`  FAILED     ${check.id}: observed ${check.observed}, expected ${check.expected}`);
        }
    }
}
process.exit(0);

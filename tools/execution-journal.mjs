#!/usr/bin/env node
// Durable record of what was prepared, sent, and what came of it.
//
// Usage:
//   node tools/execution-journal.mjs record --plan <plan.json> [--rpc-url <url>]
//   node tools/execution-journal.mjs sent   --id <id> [--tx <hash>] [--no-response]
//   node tools/execution-journal.mjs sync   --id <id> [--rpc-url <url>] [--scan-blocks <n>]
//   node tools/execution-journal.mjs list   [--json]
//
// Exit codes: 0 done, 1 refused or unresolved, 2 bad arguments.
//
// States: prepared → pending → confirmed | reverted, or unknown when the answer
// to a send was lost. The journal never sends anything and never decides to send
// again: an entry that is not settled blocks preparing the same plan twice,
// because a second successful creation is a second vault.

import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { relative, resolve } from "node:path";
import { ChainError, checksum, providerUrl, rpc } from "./lib/chain.mjs";
import { InputError, readJsonOrThrow, repoRoot } from "./lib/vault-config.mjs";

const journalRoot = resolve(process.env.FUSION_JOURNAL_DIR ?? resolve(repoRoot, ".fusion/journal"));
const settled = new Set(["confirmed", "reverted"]);

function die(code, message) {
    console.error(`vault:journal: ${code}: ${message}`);
    process.exit(code === "INVALID_ARGUMENT" || code.endsWith("_UNREADABLE") ? 2 : 1);
}

function parseArgs(argv) {
    const command = argv[0];
    if (!["record", "sent", "sync", "list"].includes(command)) {
        die("INVALID_ARGUMENT", "expected one of: record, sent, sync, list");
    }
    const values = {};
    const rest = [];
    for (const arg of argv.slice(1)) {
        if (arg === "--json" || arg === "--no-response") values[arg] = true;
        else rest.push(arg);
    }
    for (let index = 0; index < rest.length; index += 2) {
        const flag = rest[index];
        const value = rest[index + 1];
        if (!value || !["--plan", "--id", "--tx", "--rpc-url", "--scan-blocks"].includes(flag)) {
            die("INVALID_ARGUMENT", `unexpected argument "${flag}"`);
        }
        values[flag] = value;
    }
    return { command, values };
}

const { command, values } = parseArgs(process.argv.slice(2));

function entries() {
    if (!existsSync(journalRoot)) return [];
    return readdirSync(journalRoot)
        .filter((name) => name.endsWith(".json"))
        .map((name) => JSON.parse(readFileSync(resolve(journalRoot, name), "utf8")));
}

function write(entry) {
    mkdirSync(journalRoot, { recursive: true });
    entry.updatedAt = new Date().toISOString().replace(/\.\d+Z$/, "Z");
    writeFileSync(resolve(journalRoot, `${entry.id}.json`), `${JSON.stringify(entry, null, 4)}\n`);
    return entry;
}

function load(id) {
    const path = resolve(journalRoot, `${id}.json`);
    if (!existsSync(path)) die("UNKNOWN_ENTRY", `no journal entry ${id}`);
    return JSON.parse(readFileSync(path, "utf8"));
}

async function endpoint(chainId) {
    if (values["--rpc-url"]) return { name: "--rpc-url override", url: values["--rpc-url"] };
    return providerUrl(chainId);
}

try {
    if (command === "list") {
        const all = entries().sort((left, right) => left.createdAt.localeCompare(right.createdAt));
        if (values["--json"]) {
            process.stdout.write(`${JSON.stringify({ schemaVersion: 1, entries: all }, null, 4)}\n`);
        } else {
            for (const entry of all) {
                console.log(`${entry.id}  ${entry.state.padEnd(9)} nonce ${entry.nonce}  ${entry.txHash ?? "-"}  ${entry.plan.path}`);
            }
            if (all.length === 0) console.log("the journal is empty");
        }
        process.exit(0);
    }

    if (command === "record") {
        if (!values["--plan"]) die("INVALID_ARGUMENT", "missing --plan");
        const planPath = resolve(values["--plan"]);
        const plan = readJsonOrThrow(planPath, "PLAN_UNREADABLE");
        if (plan.kind !== "vault-creation" || plan.status !== "planned") {
            die("INVALID_PLAN", `${relative(repoRoot, planPath)} is not a planned vault creation`);
        }
        const planHash = `0x${createHash("sha256").update(readFileSync(planPath)).digest("hex")}`;

        // One unsettled entry per plan and caller: preparing a second send while
        // the first is unresolved is how a duplicate vault gets created.
        const clash = entries().find(
            (entry) =>
                entry.plan.sha256 === planHash &&
                entry.transaction.from.toLowerCase() === plan.transaction.from.toLowerCase() &&
                !settled.has(entry.state),
        );
        if (clash) {
            die(
                "DUPLICATE_IN_FLIGHT",
                `entry ${clash.id} for this plan and caller is still "${clash.state}"; resolve it with sync before preparing another send`,
            );
        }

        const { name, url } = await endpoint(plan.chainId);
        const nonce = await rpc(url, "eth_getTransactionCount", [plan.transaction.from, "pending"]);
        if (nonce.error) throw new ChainError("RPC_UNAVAILABLE", `${name} did not answer`);

        const entry = write({
            schemaVersion: 1,
            id: `${plan.chainId}-${planHash.slice(2, 10)}-${Date.now().toString(36)}`,
            state: "prepared",
            chainId: plan.chainId,
            deploymentId: plan.deploymentId,
            plan: { path: relative(repoRoot, planPath), sha256: planHash, builtAtBlock: plan.readBlock.number },
            transaction: {
                from: checksum(plan.transaction.from),
                to: checksum(plan.transaction.to),
                dataSha256: `0x${createHash("sha256").update(plan.transaction.data).digest("hex")}`,
            },
            nonce: Number.parseInt(nonce.result, 16),
            txHash: null,
            result: null,
            history: [{ at: new Date().toISOString().replace(/\.\d+Z$/, "Z"), state: "prepared" }],
            createdAt: new Date().toISOString().replace(/\.\d+Z$/, "Z"),
        });
        console.log(`vault:journal: prepared ${entry.id} (nonce ${entry.nonce})`);
        process.exit(0);
    }

    if (command === "sent") {
        if (!values["--id"]) die("INVALID_ARGUMENT", "missing --id");
        const entry = load(values["--id"]);
        if (settled.has(entry.state)) die("ALREADY_SETTLED", `entry ${entry.id} is already "${entry.state}"`);

        if (values["--no-response"]) {
            // The send left, the answer did not come back. This is the state that
            // must never be resolved by sending again.
            entry.state = "unknown";
            entry.history.push({ at: new Date().toISOString().replace(/\.\d+Z$/, "Z"), state: "unknown", note: "no response to the send" });
            write(entry);
            console.log(`vault:journal: unknown ${entry.id} — resolve with: sync --id ${entry.id}`);
            process.exit(0);
        }
        if (!values["--tx"] || !/^0x[0-9a-fA-F]{64}$/.test(values["--tx"])) {
            die("INVALID_ARGUMENT", "sent needs --tx <32-byte hash> or --no-response");
        }
        entry.state = "pending";
        entry.txHash = values["--tx"];
        entry.history.push({ at: new Date().toISOString().replace(/\.\d+Z$/, "Z"), state: "pending", txHash: entry.txHash });
        write(entry);
        console.log(`vault:journal: pending ${entry.id} ${entry.txHash}`);
        process.exit(0);
    }

    // sync
    if (!values["--id"]) die("INVALID_ARGUMENT", "missing --id");
    const entry = load(values["--id"]);
    const { name, url } = await endpoint(entry.chainId);
    const scanBlocks = Number(values["--scan-blocks"] ?? 50);

    const settle = (receipt, hash) => {
        entry.txHash = hash;
        entry.state = receipt.status === "0x1" ? "confirmed" : "reverted";
        entry.result = {
            blockNumber: Number.parseInt(receipt.blockNumber, 16),
            gasUsed: Number.parseInt(receipt.gasUsed, 16),
            status: receipt.status,
        };
        entry.history.push({ at: new Date().toISOString().replace(/\.\d+Z$/, "Z"), state: entry.state, txHash: hash });
        write(entry);
        console.log(`vault:journal: ${entry.state} ${entry.id} ${hash} (block ${entry.result.blockNumber})`);
        console.log(`  resolve the created addresses with: npm run vault:verify -- --chain ${entry.chainId} --tx ${hash}`);
        process.exit(0);
    };

    if (entry.txHash) {
        const receipt = (await rpc(url, "eth_getTransactionReceipt", [entry.txHash])).result;
        if (receipt) settle(receipt, entry.txHash);
        const known = (await rpc(url, "eth_getTransactionByHash", [entry.txHash])).result;
        console.log(`vault:journal: ${known ? "pending" : "unknown"} ${entry.id} ${entry.txHash}`);
        console.log(known ? "  the transaction is in the pool; do not send the creation again" : "  the endpoint does not know this hash; check the sender's nonce before doing anything");
        process.exit(1);
    }

    // No hash: the only honest thing to do is look at what the account did.
    const current = Number.parseInt((await rpc(url, "eth_getTransactionCount", [entry.transaction.from, "latest"])).result, 16);
    if (current <= entry.nonce) {
        console.log(`vault:journal: unknown ${entry.id}`);
        console.log(`  nonce ${entry.nonce} has not been used (account is at ${current}); nothing was mined from this send`);
        console.log("  a resend is a decision for a person, not for this tool");
        process.exit(1);
    }

    // The nonce was used: find that transaction rather than assume its outcome.
    const head = Number.parseInt((await rpc(url, "eth_blockNumber", [])).result, 16);
    for (let number = head; number > Math.max(0, head - scanBlocks); number -= 1) {
        const block = (await rpc(url, "eth_getBlockByNumber", [`0x${number.toString(16)}`, true])).result;
        if (!block) continue;
        const match = block.transactions.find(
            (transaction) =>
                transaction.from.toLowerCase() === entry.transaction.from.toLowerCase() &&
                Number.parseInt(transaction.nonce, 16) === entry.nonce,
        );
        if (match) {
            const receipt = (await rpc(url, "eth_getTransactionReceipt", [match.hash])).result;
            if (receipt) settle(receipt, match.hash);
        }
    }

    console.log(`vault:journal: unknown ${entry.id}`);
    console.log(`  nonce ${entry.nonce} was used (account is at ${current}) but no matching transaction was found in the last ${scanBlocks} block(s) on ${name}`);
    console.log("  widen the search with --scan-blocks or look the sender up on an explorer; do not send the creation again until this is resolved");
    process.exit(1);
} catch (error) {
    if (!(error instanceof ChainError) && !(error instanceof InputError)) throw error;
    die(error.code, error.message);
}

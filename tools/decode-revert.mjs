#!/usr/bin/env node
// Names the reason a call reverted.
//
// Usage:
//   node tools/decode-revert.mjs --data 0x…                       decode raw revert data
//   node tools/decode-revert.mjs --tx <hash> --chain <id> [--rpc-url <url>]
//                                                               replay a mined transaction at its parent block
//                                                               and decode what it reverts with
//   add --json for the full record instead of one line
//
// Exit codes: 0 decoded (including "unknown" and "empty"), 1 the transaction
// did not revert on replay, 2 bad input or the endpoint did not answer.

import { providerUrl, revertDataOf, rpcRaw } from "./lib/chain.mjs";
import { decodeRevert, loadErrorMap } from "./lib/revert-decoder.mjs";

function die(code, message) {
    console.error(`revert:decode: ${code}: ${message}`);
    process.exit(2);
}

const argv = process.argv.slice(2);
const values = {};
let json = false;
for (let index = 0; index < argv.length; index += 1) {
    const flag = argv[index];
    if (flag === "--json") {
        json = true;
        continue;
    }
    const value = argv[index + 1];
    if (!["--data", "--tx", "--chain", "--rpc-url"].includes(flag) || value === undefined) {
        die("INVALID_ARGUMENT", "expected --data <hex> | --tx <hash> --chain <id> [--rpc-url <url>] [--json]");
    }
    values[flag] = value;
    index += 1;
}
if (!values["--data"] && !values["--tx"]) die("INVALID_ARGUMENT", "give --data or --tx");

let errorMap;
try {
    errorMap = loadErrorMap();
} catch (error) {
    die("ERROR_MAP_UNREADABLE", `catalog/errors.json: ${error.message}`);
}

let data = values["--data"];
let replay = null;
if (values["--tx"]) {
    if (!/^[1-9][0-9]*$/.test(values["--chain"] ?? "")) die("INVALID_ARGUMENT", "--tx needs --chain <id>");
    const chainId = Number(values["--chain"]);
    const provider = values["--rpc-url"]
        ? { name: "--rpc-url override", url: values["--rpc-url"] }
        : providerUrl(chainId);
    const lookup = await rpcRaw(provider.url, "eth_getTransactionByHash", [values["--tx"]]);
    if (lookup.error) die("RPC_UNAVAILABLE", `${provider.name} did not answer: ${lookup.error.message}`);
    const transaction = lookup.result;
    if (!transaction) die("TRANSACTION_UNKNOWN", `the endpoint does not know ${values["--tx"]}`);
    if (transaction.blockNumber === null) die("TRANSACTION_PENDING", "the transaction is not in a block yet");
    const parent = `0x${(Number.parseInt(transaction.blockNumber, 16) - 1).toString(16)}`;
    const call = { from: transaction.from, to: transaction.to, data: transaction.input, value: transaction.value };
    const response = await rpcRaw(provider.url, "eth_call", [call, parent]);
    replay = { blockTag: parent, provider: provider.name };
    if (!response.error) {
        const record = {
            status: "did-not-revert",
            transaction: values["--tx"],
            replay,
            note: "replayed at the parent block the call succeeds; the revert depended on state inside the block or on gas",
        };
        console.log(json ? JSON.stringify(record, null, 4) : `revert:decode: ${record.note}`);
        process.exit(1);
    }
    data = revertDataOf(response.error) ?? "0x";
}

const decoded = decodeRevert(data, errorMap);
if (json) {
    console.log(JSON.stringify({ status: "decoded", data, replay, ...decoded }, null, 4));
} else {
    const where = decoded.declaredIn.length > 0 ? ` [${decoded.declaredIn.join(", ")}]` : "";
    console.log(`${decoded.text}${where}`);
}

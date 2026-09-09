#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const repoRoot = resolve(import.meta.dirname, "..");
const provenancePath = resolve(
    repoRoot,
    "abi/fusion-factory-ethereum-0xf19c1e9f6616f6056af1e322a86fdaaaaf0263f5/provenance.json",
);
const provenance = JSON.parse(readFileSync(provenancePath, "utf8"));
const abiPath = resolve(repoRoot, provenance.abi.path);
const abiBytes = readFileSync(abiPath);
const abi = JSON.parse(abiBytes);

function cast(args) {
    const result = spawnSync("cast", args, { cwd: repoRoot, encoding: "utf8" });
    if (result.error || result.status !== 0) {
        throw new Error(`cast ${args[0]} failed`);
    }
    return result.stdout.trim();
}

assert.equal(createHash("sha256").update(abiBytes).digest("hex"), provenance.abi.sha256, "ABI SHA-256 mismatch");
assert.equal(abi.length, provenance.abi.entries, "ABI entry count mismatch");

const clone = abi.filter((entry) => entry.type === "function" && entry.name === "clone");
assert.equal(clone.length, 1, "expected exactly one clone function");
const signature = `clone(${clone[0].inputs.map((input) => input.type).join(",")})`;
assert.equal(signature, provenance.creationOperation.signature, "clone signature mismatch");
assert.equal(cast(["sig", signature]), provenance.creationOperation.selector, "clone selector mismatch");
const currentMethods = spawnSync(
    "forge",
    ["inspect", "contracts/factory/FusionFactory.sol:FusionFactory", "methodIdentifiers", "--json"],
    { cwd: repoRoot, encoding: "utf8" },
);
assert.equal(currentMethods.status, 0, "forge inspect failed for current FusionFactory");
assert.equal(
    JSON.parse(currentMethods.stdout)[signature],
    provenance.creationOperation.selector.slice(2),
    "current checkout requires an ABI adapter for clone",
);

const expected = [
    "Pilot Vault",
    "PILOT",
    "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    86400,
    "0x1111111111111111111111111111111111111111",
    0,
];
const calldata = cast(["calldata", signature, ...expected.map(String)]);
assert.ok(calldata.startsWith(provenance.creationOperation.selector), "calldata selector mismatch");
const decoded = JSON.parse(cast(["decode-calldata", "--json", signature, calldata]));
assert.deepEqual(decoded, expected, "clone calldata did not decode to its inputs");

console.log(
    `valid pilot ABI: ${provenance.implementation.contractName} ${provenance.implementation.address} (${abi.length} entries, ${signature})`,
);

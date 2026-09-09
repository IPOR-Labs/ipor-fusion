#!/usr/bin/env node
// Validates catalog/fuses.json against its schema and against the checkout.
//
// Usage:
//   node tools/validate-catalog.mjs [catalog.json]
//
// Exit codes: 0 valid, 1 invalid, 2 could not read an input file.
//
// Beyond the schema it checks the things a stale catalog gets wrong: paths that
// no longer exist, a market constant that no longer holds that value, a selector
// that does not match its signature, and any deployment presented as usable
// without having been observed on chain.

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { basename, relative, resolve } from "node:path";
import { validateSchema } from "./lib/json-schema.mjs";
import { findStruct, SolidityReadError } from "./lib/solidity-abi.mjs";

const repoRoot = resolve(import.meta.dirname, "..");
const schemaPath = resolve(repoRoot, "catalog/fuses.schema.json");
const defaultCatalog = resolve(repoRoot, "catalog/fuses.json");

function readJson(path) {
    try {
        return JSON.parse(readFileSync(path, "utf8"));
    } catch (error) {
        console.error(`validate:catalog: UNREADABLE: ${path}: ${error.message}`);
        process.exit(2);
    }
}

const catalogPath = resolve(process.argv[2] ?? defaultCatalog);
const schema = readJson(schemaPath);
const catalog = readJson(catalogPath);
const errors = [];
const fail = (where, message) => errors.push(`${where}: ${message}`);

for (const error of validateSchema(catalog, schema)) errors.push(error);

function selectorOf(signature) {
    const result = spawnSync("cast", ["sig", signature], { cwd: repoRoot, encoding: "utf8" });
    if (result.status !== 0) return null;
    return result.stdout.trim();
}

/// Value of a market constant as written in IporFusionMarkets.sol: a plain
/// number with optional underscores, or `type(uint256).max - n`.
function constantValue(text) {
    const literal = /^([0-9_]+)$/.exec(text.trim());
    if (literal) return BigInt(literal[1].replaceAll("_", ""));
    const max = /^type\(uint256\)\.max(?:\s*-\s*([0-9_]+))?$/.exec(text.trim());
    if (max) return (1n << 256n) - 1n - BigInt((max[1] ?? "0").replaceAll("_", ""));
    return null;
}

function marketIdOf(integration) {
    const id = integration.market?.id;
    if (typeof id === "number") return BigInt(id);
    if (typeof id === "string" && /^[0-9]+$/.test(id)) return BigInt(id);
    return null;
}

/// Checks every described operation of one fuse against its source and, when
/// present, against the generated structure.
function checkInterface(where, fusePath, iface) {
    const operations = Object.keys(iface ?? {}).filter((key) => key !== "generated");
    if (operations.length === 0) fail(`${where}`, "describes no operation (enter, exit or claim)");

    const sourcePath = resolve(repoRoot, fusePath ?? "");
    const text = existsSync(sourcePath) ? readFileSync(sourcePath, "utf8") : null;

    for (const operation of operations) {
        const entry = iface[operation];
        // Operation names are free (enter, exit, claim, claimMainRewards, ...), so the schema
        // cannot pin their shape; check each against the operation definition here.
        for (const error of validateSchema(
            entry,
            { $defs: schema.$defs, ...schema.$defs.operation },
            `${where}.${operation}`,
        )) {
            errors.push(error);
        }
        if (!entry || typeof entry !== "object") continue;
        const selector = selectorOf(entry.signature);
        if (selector === null) {
            fail(`${where}.${operation}.signature`, `cast could not hash "${entry.signature}"`);
        } else if (selector !== entry.selector) {
            fail(`${where}.${operation}.selector`, `signature hashes to ${selector}, catalog says ${entry.selector}`);
        }
        if (text === null) continue;
        // When the compiler artifact of the fuse is present, the selector must be one it emits.
        const contractName = basename(fusePath, ".sol");
        const artifact = resolve(repoRoot, "out", `${contractName}.sol`, `${contractName}.json`);
        if (existsSync(artifact)) {
            const identifiers = JSON.parse(readFileSync(artifact, "utf8")).methodIdentifiers ?? {};
            const emitted = Object.values(identifiers).map((id) => `0x${id}`);
            if (!emitted.includes(entry.selector)) {
                fail(
                    `${where}.${operation}.selector`,
                    `${entry.selector} is not among the selectors the compiled ${contractName} emits`,
                );
            }
        }
        if (entry.struct === null) {
            // The function itself must exist; its arity is compared through the generated data.
            if (!new RegExp(`function\\s+${operation}\\s*\\(`).test(text)) {
                fail(`${where}.${operation}`, `function ${operation} is not declared in ${fusePath}`);
            }
            continue;
        }
        let declared;
        try {
            declared = findStruct(repoRoot, text, fusePath, entry.struct).fields.length;
        } catch (error) {
            if (!(error instanceof SolidityReadError)) throw error;
            fail(`${where}.${operation}.struct`, `${entry.struct} is not declared in ${fusePath} or its imports`);
            continue;
        }
        if (declared !== entry.fields.length) {
            fail(
                `${where}.${operation}.fields`,
                `${entry.struct} declares ${declared} field(s), the catalog documents ${entry.fields.length}`,
            );
        }
    }

    // The editorial description must describe the generated structure, when one exists.
    const generated = iface?.generated;
    if (!generated) return;
    for (const operation of operations) {
        const editorial = iface[operation];
        const structural = generated.operations?.[operation];
        if (!structural) {
            fail(`${where}.generated.operations`, `no generated data for ${operation}`);
            continue;
        }
        if (structural.signature !== editorial.signature || structural.selector !== editorial.selector) {
            fail(
                `${where}.${operation}`,
                `generated ${structural.signature} ${structural.selector} disagrees with the described ${editorial.signature} ${editorial.selector}`,
            );
        }
        const described = editorial.fields.map((field) => `${field.type} ${field.name}`).join(", ");
        const actual = structural.fields.map((field) => `${field.type} ${field.name}`).join(", ");
        if (described !== actual) {
            fail(`${where}.${operation}.fields`, `described [${described}] but the struct is [${actual}]`);
        }
    }
    for (const operation of Object.keys(generated.operations ?? {})) {
        if (!operations.includes(operation)) {
            fail(`${where}.generated.operations`, `generated data for ${operation} has no description`);
        }
    }
}

function checkDeployment(at, contract, marketId) {
    if (!contract || typeof contract !== "object") return;
    // The schema only says "object or null" for a nullable deployment; check the shape here.
    for (const error of validateSchema(contract, { $defs: schema.$defs, ...schema.$defs.deployedContract }, at))
        errors.push(error);
    if (contract.status === "observed") {
        for (const field of ["address", "observedAtBlock", "runtimeCodeHash"]) {
            if (contract[field] === null || contract[field] === undefined) {
                fail(at, `status "observed" requires ${field}`);
            }
        }
        // A contract without MARKET_ID (some reward fuses) cannot report one; the note must say so.
        if (contract.observedMarketId === null || contract.observedMarketId === undefined) {
            if (!(contract.notes ?? []).some((note) => /MARKET_ID/.test(note))) {
                fail(
                    at,
                    'status "observed" requires observedMarketId, or a note explaining that the source declares no MARKET_ID',
                );
            }
        }
        const observed = contract.observedMarketId;
        const observedId =
            typeof observed === "number" ? BigInt(observed) : typeof observed === "string" ? BigInt(observed) : null;
        if (observedId !== null && marketId !== null && observedId !== marketId) {
            fail(at, `observed market ${observed} is not this integration's market ${marketId}`);
        }
    } else {
        if (
            contract.observedAtBlock !== null ||
            contract.runtimeCodeHash !== null ||
            contract.observedMarketId !== null
        ) {
            fail(at, `status "${contract.status}" must not carry observation data`);
        }
        if (contract.status === "unverified" && contract.address === null) {
            fail(at, 'status "unverified" needs the address it was taken from');
        }
        if ((contract.status === "unknown" || contract.status === "absent") && contract.address !== null) {
            fail(at, `status "${contract.status}" cannot name an address`);
        }
    }
    if (contract.matchesCurrentSource === true && contract.status !== "observed") {
        fail(at, "a deployment cannot match the current source without having been observed");
    }
}

const ids = new Set();
for (const [index, integration] of (catalog.integrations ?? []).entries()) {
    if (!integration || typeof integration !== "object") continue;
    const where = `$.integrations[${index}]`;

    if (ids.has(integration.id)) fail(`${where}.id`, `duplicate id "${integration.id}"`);
    ids.add(integration.id);

    const paths = [
        ["source.actionFuse", integration.source?.actionFuse],
        ["source.balanceFuse", integration.source?.balanceFuse],
        ["market.constantSource", integration.market?.constantSource],
    ];
    (integration.additionalFuses ?? []).forEach((fuse, fuseIndex) =>
        paths.push([`additionalFuses[${fuseIndex}].path`, fuse?.path]),
    );
    for (const [key, path] of paths) {
        if (typeof path === "string" && !existsSync(resolve(repoRoot, path))) {
            fail(`${where}.${key}`, `path does not exist in this checkout: ${path}`);
        }
    }
    for (const [testIndex, path] of (integration.tests ?? []).entries()) {
        if (!existsSync(resolve(repoRoot, path))) {
            fail(`${where}.tests[${testIndex}]`, `path does not exist in this checkout: ${path}`);
        }
    }

    // The market constant must still hold the catalogued value; a market
    // without a constant must say where its id comes from.
    const marketId = marketIdOf(integration);
    const constant = integration.market?.constant;
    const constantSource = integration.market?.constantSource;
    if (constant === null || constant === undefined) {
        if (constantSource !== null && constantSource !== undefined) {
            fail(`${where}.market.constantSource`, "a market without a constant cannot name a constant source");
        }
        if (!integration.market?.origin) {
            fail(`${where}.market.origin`, "a market without a constant must state where its id comes from");
        }
    } else if (typeof constantSource === "string" && existsSync(resolve(repoRoot, constantSource))) {
        const text = readFileSync(resolve(repoRoot, constantSource), "utf8");
        const match = new RegExp(`constant\\s+${constant}\\s*=\\s*([^;]+);`).exec(text);
        if (!match) {
            fail(`${where}.market.constant`, `${constant} is not defined in ${constantSource}`);
        } else {
            const value = constantValue(match[1]);
            if (value === null) {
                fail(
                    `${where}.market.constant`,
                    `${constant} is "${match[1].trim()}" in the source, which this validator cannot evaluate`,
                );
            } else if (marketId === null || value !== marketId) {
                fail(
                    `${where}.market.id`,
                    `${constant} is ${match[1].trim()} in the source, the catalog says ${integration.market?.id}`,
                );
            }
        }
    }

    checkInterface(`${where}.interface`, integration.source?.actionFuse, integration.interface);
    (integration.additionalFuses ?? []).forEach((fuse, fuseIndex) => {
        checkInterface(`${where}.additionalFuses[${fuseIndex}].interface`, fuse?.path, fuse?.interface);
        checkDeployment(`${where}.additionalFuses[${fuseIndex}].deployment`, fuse?.deployment, marketId);
    });

    if (integration.source?.balanceFuse === null && integration.deployments?.balanceFuse !== null) {
        fail(
            `${where}.deployments.balanceFuse`,
            "an integration without a balance fuse source cannot list a balance fuse deployment",
        );
    }
    if (integration.source?.balanceFuse !== null && integration.deployments?.balanceFuse === null) {
        fail(
            `${where}.deployments.balanceFuse`,
            'the balance fuse needs a deployment entry (use status "unknown" when none was found)',
        );
    }
    for (const [key, contract] of Object.entries(integration.deployments ?? {})) {
        checkDeployment(`${where}.deployments.${key}`, contract, marketId);
    }
}

if (errors.length > 0) {
    console.error(`invalid catalog: ${relative(repoRoot, catalogPath)}`);
    for (const error of errors) console.error(`  ${error}`);
    process.exit(1);
}

console.log(`valid catalog: ${catalog.integrations.length} integration(s) checked`);

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
import { relative, resolve } from "node:path";
import { validateSchema } from "./lib/json-schema.mjs";

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

const ids = new Set();
for (const [index, integration] of (catalog.integrations ?? []).entries()) {
    if (!integration || typeof integration !== "object") continue;
    const where = `$.integrations[${index}]`;

    if (ids.has(integration.id)) fail(`${where}.id`, `duplicate id "${integration.id}"`);
    ids.add(integration.id);

    for (const [key, path] of [
        ["source.actionFuse", integration.source?.actionFuse],
        ["source.balanceFuse", integration.source?.balanceFuse],
        ["market.constantSource", integration.market?.constantSource],
    ]) {
        if (typeof path === "string" && !existsSync(resolve(repoRoot, path))) {
            fail(`${where}.${key}`, `path does not exist in this checkout: ${path}`);
        }
    }
    for (const [testIndex, path] of (integration.tests ?? []).entries()) {
        if (!existsSync(resolve(repoRoot, path))) {
            fail(`${where}.tests[${testIndex}]`, `path does not exist in this checkout: ${path}`);
        }
    }

    // The market constant must still hold the catalogued value.
    const constantSource = integration.market?.constantSource;
    if (typeof constantSource === "string" && existsSync(resolve(repoRoot, constantSource))) {
        const text = readFileSync(resolve(repoRoot, constantSource), "utf8");
        const match = new RegExp(`constant\\s+${integration.market.constant}\\s*=\\s*([0-9_]+)`).exec(text);
        if (!match) {
            fail(`${where}.market.constant`, `${integration.market.constant} is not defined in ${constantSource}`);
        } else if (Number(match[1].replaceAll("_", "")) !== integration.market.id) {
            fail(
                `${where}.market.id`,
                `${integration.market.constant} is ${match[1]} in the source, the catalog says ${integration.market.id}`,
            );
        }
    }

    for (const operation of ["enter", "exit"]) {
        const entry = integration.interface?.[operation];
        if (!entry) continue;
        const selector = selectorOf(entry.signature);
        if (selector === null) {
            fail(`${where}.interface.${operation}.signature`, `cast could not hash "${entry.signature}"`);
        } else if (selector !== entry.selector) {
            fail(`${where}.interface.${operation}.selector`, `signature hashes to ${selector}, catalog says ${entry.selector}`);
        }
        // The struct must exist in the action fuse source with the catalogued arity.
        const sourcePath = resolve(repoRoot, integration.source?.actionFuse ?? "");
        if (existsSync(sourcePath)) {
            const text = readFileSync(sourcePath, "utf8");
            const struct = new RegExp(`struct\\s+${entry.struct}\\s*\\{([^}]*)\\}`).exec(text);
            if (!struct) {
                fail(`${where}.interface.${operation}.struct`, `${entry.struct} is not declared in ${integration.source.actionFuse}`);
            } else {
                const declared = struct[1]
                    .split(";")
                    .map((line) => line.replace(/\/\/[^\n]*/g, "").trim())
                    .filter(Boolean).length;
                if (declared !== entry.fields.length) {
                    fail(
                        `${where}.interface.${operation}.fields`,
                        `${entry.struct} declares ${declared} field(s), the catalog documents ${entry.fields.length}`,
                    );
                }
            }
        }
    }

    // The editorial description must describe the generated structure, when one exists.
    const generated = integration.interface?.generated;
    if (generated) {
        for (const operation of ["enter", "exit"]) {
            const editorial = integration.interface[operation];
            const structural = generated.operations?.[operation];
            if (!structural) {
                fail(`${where}.interface.generated.operations`, `no generated data for ${operation}`);
                continue;
            }
            if (structural.signature !== editorial.signature || structural.selector !== editorial.selector) {
                fail(
                    `${where}.interface.${operation}`,
                    `generated ${structural.signature} ${structural.selector} disagrees with the described ${editorial.signature} ${editorial.selector}`,
                );
            }
            const described = editorial.fields.map((field) => `${field.type} ${field.name}`).join(", ");
            const actual = structural.fields.map((field) => `${field.type} ${field.name}`).join(", ");
            if (described !== actual) {
                fail(`${where}.interface.${operation}.fields`, `described [${described}] but the struct is [${actual}]`);
            }
        }
    }

    for (const [key, contract] of Object.entries(integration.deployments ?? {})) {
        if (!contract) continue;
        const at = `${where}.deployments.${key}`;
        if (contract.status === "observed") {
            for (const field of ["observedAtBlock", "runtimeCodeHash", "observedMarketId"]) {
                if (contract[field] === null || contract[field] === undefined) {
                    fail(at, `status "observed" requires ${field}`);
                }
            }
            if (contract.observedMarketId !== integration.market?.id) {
                fail(at, `observed market ${contract.observedMarketId} is not this integration's market ${integration.market?.id}`);
            }
        } else if (contract.observedAtBlock !== null || contract.runtimeCodeHash !== null) {
            fail(at, `status "${contract.status}" must not carry observation data`);
        }
        if (contract.matchesCurrentSource === true && contract.status !== "observed") {
            fail(at, "a deployment cannot match the current source without having been observed");
        }
    }
}

if (errors.length > 0) {
    console.error(`invalid catalog: ${relative(repoRoot, catalogPath)}`);
    for (const error of errors) console.error(`  ${error}`);
    process.exit(1);
}

console.log(`valid catalog: ${catalog.integrations.length} integration(s) checked`);

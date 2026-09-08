#!/usr/bin/env node
// Validates config/test-suites.json against config/test-suites.schema.json.
//
// Usage:
//   node tools/validate-test-suites.mjs [catalog.json] [schema.json]
//
// Exit codes: 0 valid, 1 invalid, 2 could not read an input file.
// Implements the subset of JSON Schema the catalog schema actually uses, so that
// the schema file stays the single description of the format and this script does
// not add a dependency to the repository.

import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const catalogPath = process.argv[2] ?? resolve(repoRoot, "config/test-suites.json");
const schemaPath = process.argv[3] ?? resolve(repoRoot, "config/test-suites.schema.json");

function readJson(path) {
    try {
        return JSON.parse(readFileSync(path, "utf8"));
    } catch (error) {
        console.error(`cannot read ${path}: ${error.message}`);
        process.exit(2);
    }
}

const schema = readJson(schemaPath);
const catalog = readJson(catalogPath);
const errors = [];

const fail = (where, message) => errors.push(`${where}: ${message}`);

function deref(node) {
    if (!node || typeof node.$ref !== "string") return node;
    const path = node.$ref.replace(/^#\//, "").split("/");
    return path.reduce((acc, key) => acc?.[key], schema);
}

function typeOf(value) {
    if (value === null) return "null";
    if (Array.isArray(value)) return "array";
    if (Number.isInteger(value)) return "integer";
    return typeof value;
}

function validate(value, rawNode, where) {
    const node = deref(rawNode);
    if (!node) return;

    if (node.type !== undefined) {
        const allowed = Array.isArray(node.type) ? node.type : [node.type];
        const actual = typeOf(value);
        const ok = allowed.some((t) => t === actual || (t === "number" && actual === "integer"));
        if (!ok) {
            fail(where, `expected type ${allowed.join(" or ")}, got ${actual}`);
            return;
        }
    }

    if (node.enum !== undefined && !node.enum.some((option) => option === value)) {
        fail(where, `value ${JSON.stringify(value)} is not one of ${JSON.stringify(node.enum)}`);
    }

    // A pattern constrains strings only; a nullable field with a pattern still allows null.
    if (node.pattern !== undefined && typeof value === "string" && !new RegExp(node.pattern).test(value)) {
        fail(where, `value ${JSON.stringify(value)} does not match ${node.pattern}`);
    }

    if (node.minLength !== undefined && typeof value === "string" && value.length < node.minLength) {
        fail(where, `string is shorter than ${node.minLength} characters`);
    }

    if (node.minimum !== undefined && typeof value === "number" && value < node.minimum) {
        fail(where, `value ${value} is below the minimum ${node.minimum}`);
    }

    if (typeOf(value) === "array") {
        if (node.minItems !== undefined && value.length < node.minItems) {
            fail(where, `expected at least ${node.minItems} item(s), got ${value.length}`);
        }
        if (node.items !== undefined) {
            value.forEach((item, index) => validate(item, node.items, `${where}[${index}]`));
        }
    }

    if (typeOf(value) === "object") {
        for (const key of node.required ?? []) {
            if (!Object.hasOwn(value, key)) fail(where, `missing required property "${key}"`);
        }
        for (const [key, child] of Object.entries(value)) {
            const childSchema = node.properties?.[key];
            if (childSchema === undefined) {
                if (node.additionalProperties === false) fail(where, `unknown property "${key}"`);
                continue;
            }
            validate(child, childSchema, `${where}.${key}`);
        }
    }
}

validate(catalog, schema, "$");

// Cross-checks the schema cannot express on its own.
if (Array.isArray(catalog.suites)) {
    const seen = new Map();

    catalog.suites.forEach((suite, index) => {
        if (!suite || typeof suite !== "object") return;
        const where = `$.suites[${index}]`;

        if (typeof suite.id === "string") {
            if (seen.has(suite.id))
                fail(where, `duplicate id "${suite.id}", first used at $.suites[${seen.get(suite.id)}]`);
            else seen.set(suite.id, index);
        }

        if (typeof suite.path === "string") {
            try {
                readFileSync(resolve(repoRoot, suite.path));
            } catch {
                fail(where, `path "${suite.path}" does not exist in this checkout`);
            }
        }

        const forks =
            suite.fixture === "fork-fresh-deployment" ||
            suite.fixture === "fork-upgrade" ||
            suite.fixture === "deployed-usage";
        if (forks) {
            if (suite.rpc === null)
                fail(where, `fixture "${suite.fixture}" needs a provider variable, but rpc is null`);
            if (suite.block === null) fail(where, `fixture "${suite.fixture}" needs a pinned block, but block is null`);
        } else if (suite.fixture === "local-deployment") {
            if (suite.rpc !== null)
                fail(where, `fixture "local-deployment" must not declare an rpc, got ${JSON.stringify(suite.rpc)}`);
            if (suite.block !== null)
                fail(where, `fixture "local-deployment" must not declare a block, got ${JSON.stringify(suite.block)}`);
        }
    });
}

if (errors.length > 0) {
    console.error(`invalid: ${catalogPath}`);
    for (const error of errors) console.error(`  ${error}`);
    process.exit(1);
}

console.log(`valid: ${catalogPath} (${catalog.suites.length} suite(s) classified)`);

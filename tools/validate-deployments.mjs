#!/usr/bin/env node

import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const schemaPath = resolve(repoRoot, "deployments/schema/factories.schema.json");
const fixturePath = resolve(repoRoot, "test/fixtures/deployments/valid-candidate.json");

function readJson(path) {
    try {
        return JSON.parse(readFileSync(path, "utf8"));
    } catch (error) {
        throw new Error(`cannot read ${path}: ${error.message}`);
    }
}

function productionManifests() {
    const root = resolve(repoRoot, "deployments");
    return readdirSync(root, { withFileTypes: true })
        .filter((entry) => entry.isDirectory() && /^[1-9][0-9]*$/.test(entry.name))
        .map((entry) => resolve(root, entry.name, "factories.json"))
        .filter(existsSync);
}

const schema = readJson(schemaPath);
const inputs =
    process.argv.length > 2
        ? process.argv.slice(2).map((path) => resolve(path))
        : [fixturePath, ...productionManifests()];
const errors = [];
const fail = (file, where, message) => errors.push(`${relative(repoRoot, file)} ${where}: ${message}`);

function deref(node) {
    if (!node || typeof node.$ref !== "string") return node;
    return node.$ref
        .replace(/^#\//, "")
        .split("/")
        .reduce((value, key) => value?.[key], schema);
}

function typeOf(value) {
    if (value === null) return "null";
    if (Array.isArray(value)) return "array";
    if (Number.isInteger(value)) return "integer";
    return typeof value;
}

function validateSchema(file, value, rawNode, where) {
    const node = deref(rawNode);
    if (!node) return;
    const actual = typeOf(value);
    if (node.type !== undefined) {
        const allowed = Array.isArray(node.type) ? node.type : [node.type];
        if (!allowed.includes(actual)) {
            fail(file, where, `expected type ${allowed.join(" or ")}, got ${actual}`);
            return;
        }
    }
    if (node.enum && !node.enum.includes(value)) {
        fail(file, where, `value ${JSON.stringify(value)} is not one of ${JSON.stringify(node.enum)}`);
    }
    if (node.pattern && typeof value === "string" && !new RegExp(node.pattern).test(value)) {
        fail(file, where, `value ${JSON.stringify(value)} does not match ${node.pattern}`);
    }
    if (node.minLength !== undefined && typeof value === "string" && value.length < node.minLength) {
        fail(file, where, `string is shorter than ${node.minLength} characters`);
    }
    if (node.minimum !== undefined && typeof value === "number" && value < node.minimum) {
        fail(file, where, `value ${value} is below minimum ${node.minimum}`);
    }
    if (actual === "array") {
        if (node.minItems !== undefined && value.length < node.minItems) {
            fail(file, where, `expected at least ${node.minItems} item(s), got ${value.length}`);
        }
        value.forEach((item, index) => validateSchema(file, item, node.items, `${where}[${index}]`));
    }
    if (actual === "object") {
        for (const key of node.required ?? []) {
            if (!Object.hasOwn(value, key)) fail(file, where, `missing required property "${key}"`);
        }
        for (const [key, child] of Object.entries(value)) {
            const childSchema = node.properties?.[key];
            if (childSchema) {
                validateSchema(file, child, childSchema, `${where}.${key}`);
            } else if (node.additionalProperties === false) {
                fail(file, where, `unknown property "${key}"`);
            } else if (typeof node.additionalProperties === "object") {
                validateSchema(file, child, node.additionalProperties, `${where}.${key}`);
            }
        }
    }
}

function sha256(path) {
    return createHash("sha256").update(readFileSync(path)).digest("hex");
}

function validateManifest(file, manifest) {
    validateSchema(file, manifest, schema, "$");
    if (!Array.isArray(manifest.deployments)) return;

    const productionMatch = relative(repoRoot, file).match(/^deployments\/([1-9][0-9]*)\/factories\.json$/);
    if (productionMatch && Number(productionMatch[1]) !== manifest.chainId) {
        fail(file, "$.chainId", `directory chain ${productionMatch[1]} does not match manifest ${manifest.chainId}`);
    }

    const ids = new Set();
    for (const [index, deployment] of manifest.deployments.entries()) {
        if (!deployment || typeof deployment !== "object") continue;
        const where = `$.deployments[${index}]`;
        if (ids.has(deployment.id)) fail(file, `${where}.id`, `duplicate deployment id "${deployment.id}"`);
        ids.add(deployment.id);

        if (deployment.chainId !== manifest.chainId) {
            fail(
                file,
                `${where}.chainId`,
                `deployment chain ${deployment.chainId} does not match manifest ${manifest.chainId}`,
            );
        }
        if (/^0x0{40}$/i.test(deployment.address ?? "")) {
            fail(file, `${where}.address`, "zero address is not a deployment");
        }

        const abiPath = deployment.interface?.abiPath;
        const abiHash = deployment.interface?.abiSha256;
        if (typeof abiPath === "string") {
            const absoluteAbi = resolve(repoRoot, abiPath);
            if (!existsSync(absoluteAbi)) {
                fail(file, `${where}.interface.abiPath`, `ABI file does not exist: ${abiPath}`);
            } else if (typeof abiHash === "string" && sha256(absoluteAbi) !== abiHash) {
                fail(file, `${where}.interface.abiSha256`, `hash does not match ${abiPath}`);
            }
            if (productionMatch && !abiPath.startsWith("abi/")) {
                fail(file, `${where}.interface.abiPath`, "production manifests must reference abi/");
            }
        }

        const verification = deployment.verification;
        for (const pathKey of ["reportPath", "compatibilityTestPath"]) {
            const path = verification?.[pathKey];
            if (typeof path === "string" && !existsSync(resolve(repoRoot, path))) {
                fail(file, `${where}.verification.${pathKey}`, `referenced file does not exist: ${path}`);
            }
        }

        if (deployment.status === "verified") {
            const requiredProof = [
                "blockNumber",
                "blockHash",
                "checkedAt",
                "inspectorVersion",
                "reportPath",
                "compatibilityTestPath",
            ];
            for (const key of requiredProof) {
                if (verification?.[key] === null || verification?.[key] === undefined) {
                    fail(file, `${where}.verification.${key}`, `verified deployment requires ${key}`);
                }
            }
        }
    }
}

for (const file of inputs) {
    try {
        validateManifest(file, readJson(file));
    } catch (error) {
        errors.push(error.message);
    }
}

if (errors.length > 0) {
    console.error("invalid deployment manifests:");
    for (const error of errors) console.error(`  ${error}`);
    process.exit(1);
}

const productionCount = inputs.filter((file) =>
    /^deployments\/[1-9][0-9]*\/factories\.json$/.test(relative(repoRoot, file)),
).length;
console.log(
    `valid deployment manifests: ${inputs.length} checked (${productionCount} production, ${inputs.length - productionCount} fixture)`,
);

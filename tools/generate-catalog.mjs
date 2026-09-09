#!/usr/bin/env node
// Regenerates the structural part of catalog/fuses.json from the Solidity sources.
//
// Usage:
//   node tools/generate-catalog.mjs [--check] [catalog.json]
//
// Exit codes: 0 written (or up to date with --check), 1 out of date with
// --check, 2 could not read or parse an input.
//
// It writes exactly one subtree per integration, `interface.generated`, and
// nothing else. Field meanings, substrate semantics, roles and observed
// deployments are editorial or evidence and are never touched here.

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { relative, resolve } from "node:path";

const repoRoot = resolve(import.meta.dirname, "..");

function die(code, message) {
    console.error(`catalog:generate: ${code}: ${message}`);
    process.exit(2);
}

const args = process.argv.slice(2);
const check = args.includes("--check");
const catalogPath = resolve(args.find((arg) => arg !== "--check") ?? resolve(repoRoot, "catalog/fuses.json"));

function read(path) {
    try {
        return readFileSync(path, "utf8");
    } catch (error) {
        die("UNREADABLE", `${path}: ${error.message}`);
    }
}

const catalog = JSON.parse(read(catalogPath));

function sha256(text) {
    return `0x${createHash("sha256").update(text).digest("hex")}`;
}

function cast(args_) {
    const result = spawnSync("cast", args_, { cwd: repoRoot, encoding: "utf8" });
    if (result.status !== 0) die("CAST_FAILED", `cast ${args_.join(" ")}`);
    return result.stdout.trim();
}

/// Reads one struct declaration: field types, names and the line it starts on.
function parseStruct(source, path, name) {
    const lines = source.split("\n");
    const start = lines.findIndex((line) => new RegExp(`^\\s*struct\\s+${name}\\s*\\{`).test(line));
    if (start === -1) die("STRUCT_NOT_FOUND", `${name} is not declared in ${path}`);
    const fields = [];
    for (let index = start + 1; index < lines.length; index += 1) {
        const line = lines[index].trim();
        if (line.startsWith("}")) {
            return { struct: name, declaredAtLine: start + 1, fields };
        }
        if (line === "" || line.startsWith("//") || line.startsWith("/*") || line.startsWith("*")) continue;
        const match = /^([A-Za-z_][A-Za-z0-9_\[\]]*)\s+([A-Za-z_][A-Za-z0-9_]*)\s*;/.exec(line);
        if (!match) die("STRUCT_UNPARSEABLE", `${path}:${index + 1} in ${name}: "${line}"`);
        fields.push({ type: match[1], name: match[2], line: index + 1 });
    }
    return die("STRUCT_UNPARSEABLE", `${name} in ${path} is not closed`);
}

function generateFor(integration) {
    const actionPath = integration.source.actionFuse;
    const balancePath = integration.source.balanceFuse;
    const actionSource = read(resolve(repoRoot, actionPath));
    const balanceSource = read(resolve(repoRoot, balancePath));
    const constantSourcePath = integration.market.constantSource;
    const constantSource = read(resolve(repoRoot, constantSourcePath));

    const constantLine =
        constantSource.split("\n").findIndex((line) =>
            new RegExp(`constant\\s+${integration.market.constant}\\s*=`).test(line),
        ) + 1;
    if (constantLine === 0) die("CONSTANT_NOT_FOUND", `${integration.market.constant} in ${constantSourcePath}`);

    const operations = {};
    for (const [operation, entry] of Object.entries(integration.interface)) {
        if (operation === "generated") continue;
        const parsed = parseStruct(actionSource, actionPath, entry.struct);
        const tuple = `(${parsed.fields.map((field) => field.type).join(",")})`;
        const signature = `${operation}(${tuple})`;
        operations[operation] = {
            struct: parsed.struct,
            signature,
            selector: cast(["sig", signature]),
            source: `${actionPath}:${parsed.declaredAtLine}`,
            fields: parsed.fields.map((field) => ({
                name: field.name,
                type: field.type,
                source: `${actionPath}:${field.line}`,
            })),
        };
    }

    return {
        generator: "tools/generate-catalog.mjs",
        marketConstantSource: `${constantSourcePath}:${constantLine}`,
        sources: {
            [actionPath]: sha256(actionSource),
            [balancePath]: sha256(balanceSource),
        },
        operations,
    };
}

let changed = false;
for (const integration of catalog.integrations) {
    const generated = generateFor(integration);
    if (JSON.stringify(integration.interface.generated) !== JSON.stringify(generated)) changed = true;
    integration.interface.generated = generated;
}

const serialized = `${JSON.stringify(catalog, null, 4)}\n`;
const onDisk = read(catalogPath);

if (check) {
    if (changed || serialized !== onDisk) {
        console.error(
            `catalog:generate: OUT_OF_DATE: ${relative(repoRoot, catalogPath)} does not match the sources; run npm run catalog:generate`,
        );
        process.exit(1);
    }
    console.log(`catalog is up to date with the sources (${catalog.integrations.length} integration(s))`);
} else {
    writeFileSync(catalogPath, serialized);
    console.log(
        `${changed ? "updated" : "unchanged"}: ${relative(repoRoot, catalogPath)} (${catalog.integrations.length} integration(s))`,
    );
}

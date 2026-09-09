#!/usr/bin/env node
// Regenerates the structural part of catalog/fuses.json from the Solidity sources.
//
// Usage:
//   node tools/generate-catalog.mjs [--check] [catalog.json]
//
// Exit codes: 0 written (or up to date with --check), 1 out of date with
// --check, 2 could not read or parse an input.
//
// It writes exactly one subtree per fuse, `interface.generated` — on the
// integration for its primary action fuse and on every entry of
// `additionalFuses` — and nothing else. Field meanings, substrate semantics,
// roles and observed deployments are editorial or evidence and are never
// touched here.

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { relative, resolve } from "node:path";
import { canonicalType, findStruct, parseFunctionParams, SolidityReadError } from "./lib/solidity-abi.mjs";

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

function guarded(fn) {
    try {
        return fn();
    } catch (error) {
        if (error instanceof SolidityReadError) die(error.code, error.message);
        throw error;
    }
}

/// Structural data of every operation a fuse's `interface` describes. An
/// operation with a `struct` is read from that struct; one with `struct: null`
/// is read from the function's own parameter list.
function generateOperations(fusePath, fuseSource, iface) {
    const operations = {};
    for (const [operation, entry] of Object.entries(iface)) {
        if (operation === "generated") continue;
        const parsed = guarded(() =>
            entry.struct === null
                ? { path: fusePath, ...parseFunctionParams(fuseSource, fusePath, operation) }
                : findStruct(repoRoot, fuseSource, fusePath, entry.struct),
        );
        // Field types are resolved from the file that declares the struct, which may be an imported base.
        const declaringSource = parsed.path === fusePath ? fuseSource : read(resolve(repoRoot, parsed.path));
        const types = parsed.fields.map((field) =>
            guarded(() => canonicalType(repoRoot, declaringSource, parsed.path, field.type)),
        );
        const signature =
            entry.struct === null ? `${operation}(${types.join(",")})` : `${operation}((${types.join(",")}))`;
        operations[operation] = {
            struct: entry.struct,
            signature,
            selector: cast(["sig", signature]),
            source: `${parsed.path}:${parsed.declaredAtLine}`,
            fields: parsed.fields.map((field) => ({
                name: field.name,
                type: field.type,
                source: `${parsed.path}:${field.line}`,
            })),
        };
    }
    return operations;
}

function generateFor(integration) {
    const actionPath = integration.source.actionFuse;
    const balancePath = integration.source.balanceFuse;
    const actionSource = read(resolve(repoRoot, actionPath));
    const balanceSource = balancePath === null ? null : read(resolve(repoRoot, balancePath));

    let marketConstantSource = null;
    if (integration.market.constant !== null) {
        const constantSourcePath = integration.market.constantSource;
        const constantSource = read(resolve(repoRoot, constantSourcePath));
        const constantLine =
            constantSource
                .split("\n")
                .findIndex((line) => new RegExp(`constant\\s+${integration.market.constant}\\s*=`).test(line)) + 1;
        if (constantLine === 0) die("CONSTANT_NOT_FOUND", `${integration.market.constant} in ${constantSourcePath}`);
        marketConstantSource = `${constantSourcePath}:${constantLine}`;
    }

    const sources = { [actionPath]: sha256(actionSource) };
    if (balancePath !== null) sources[balancePath] = sha256(balanceSource);

    const generated = {
        generator: "tools/generate-catalog.mjs",
        marketConstantSource,
        sources,
        operations: generateOperations(actionPath, actionSource, integration.interface),
    };

    const additional = (integration.additionalFuses ?? []).map((fuse) => {
        const source = read(resolve(repoRoot, fuse.path));
        return {
            generator: "tools/generate-catalog.mjs",
            sources: { [fuse.path]: sha256(source) },
            operations: generateOperations(fuse.path, source, fuse.interface),
        };
    });

    return { generated, additional };
}

let changed = false;
for (const integration of catalog.integrations) {
    const { generated, additional } = generateFor(integration);
    if (JSON.stringify(integration.interface.generated) !== JSON.stringify(generated)) changed = true;
    integration.interface.generated = generated;
    (integration.additionalFuses ?? []).forEach((fuse, index) => {
        if (JSON.stringify(fuse.interface.generated) !== JSON.stringify(additional[index])) changed = true;
        fuse.interface.generated = additional[index];
    });
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

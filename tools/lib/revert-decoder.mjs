// Decodes revert data against the custom errors this repository compiles.
//
// The map is built from the compiler artifacts under out/ (forge build) for
// contracts whose compilation target lives under contracts/, so it holds the
// repository's own errors and the OpenZeppelin errors those contracts inherit.
// The committed copy is catalog/errors.json; `npm run errors:check` fails when
// it no longer matches the artifacts.

import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
import { selector as selectorOf } from "./keccak.mjs";
import { solidityFiles } from "./solidity-abi.mjs";

const repoRoot = resolve(import.meta.dirname, "../..");

export const ERROR_STRING_SELECTOR = "0x08c379a0";
export const PANIC_SELECTOR = "0x4e487b71";

/// Solidity panic codes, from the language documentation.
export const PANIC_CODES = {
    0x00: "generic compiler panic",
    0x01: "assert(false)",
    0x11: "arithmetic overflow or underflow outside unchecked",
    0x12: "division or modulo by zero",
    0x21: "conversion into an enum out of range",
    0x22: "access to an incorrectly encoded storage byte array",
    0x31: "pop() on an empty array",
    0x32: "array index out of bounds",
    0x41: "too much memory allocated or array too large",
    0x51: "call to a zero-initialized internal function",
};

function canonicalType(parameter) {
    if (!parameter.type.startsWith("tuple")) return parameter.type;
    return `(${parameter.components.map(canonicalType).join(",")})${parameter.type.slice(5)}`;
}

/// Source files under contracts/ that declare an error of the given name.
/// Errors inherited from dependencies (OpenZeppelin) have none.
function declarationsBySourceName(sourceRoot, sourceDirectory) {
    const byName = {};
    for (const file of solidityFiles(sourceRoot, [sourceDirectory])) {
        const source = readFileSync(resolve(sourceRoot, file), "utf8");
        for (const match of source.matchAll(/^\s*error\s+(\w+)\s*\(/gm)) {
            (byName[match[1]] ??= new Set()).add(file);
        }
    }
    return byName;
}

/// Walks out/ and returns { selector: { signature, name, inputs, declaredIn } }
/// for every custom error a contract compiled from `contracts/` can revert with;
/// declaredIn lists the repository source files that declare it (empty for an
/// error inherited from a dependency, such as the OpenZeppelin access errors).
export function collectErrors(
    outDir = resolve(repoRoot, "out"),
    { sourcePrefix = "contracts/", sourceRoot = repoRoot } = {},
) {
    if (!existsSync(outDir)) return null;
    const sourceDirectory = sourcePrefix.replace(/\/$/, "");
    const declared = declarationsBySourceName(sourceRoot, sourceDirectory);
    // Artifact directories are named after source files; only those with a namesake
    // under the source prefix can hold a contract compiled from it, so the other
    // (dependency) artifacts are not read at all.
    const candidates = new Set(solidityFiles(sourceRoot, [sourceDirectory]).map((file) => file.split("/").pop()));
    const errors = {};
    // forge nests artifacts of same-named source files (out/<dir>/<File>.sol/), so
    // the walk is recursive; build-info holds no ABI.
    const walk = (directory) => {
        for (const entry of readdirSync(directory).sort()) {
            const path = join(directory, entry);
            if (entry === "build-info") continue;
            if (statSync(path).isDirectory()) {
                if (entry.endsWith(".sol") && !candidates.has(entry)) continue;
                walk(path);
                continue;
            }
            if (!entry.endsWith(".json") || !directory.endsWith(".sol")) continue;
            let artifact;
            try {
                artifact = JSON.parse(readFileSync(path, "utf8"));
            } catch {
                continue;
            }
            const target = artifact.metadata?.settings?.compilationTarget ?? {};
            const [sourcePath] = Object.entries(target)[0] ?? [];
            if (!sourcePath || !sourcePath.startsWith(sourcePrefix)) continue;
            for (const abiEntry of artifact.abi ?? []) {
                if (abiEntry.type !== "error") continue;
                const signature = `${abiEntry.name}(${abiEntry.inputs.map(canonicalType).join(",")})`;
                const selector = selectorOf(signature);
                if (errors[selector]) continue;
                errors[selector] = {
                    signature,
                    name: abiEntry.name,
                    inputs: abiEntry.inputs.map((input) => ({ name: input.name, type: canonicalType(input) })),
                    declaredIn: [...(declared[abiEntry.name] ?? [])].sort(),
                };
            }
        }
    };
    walk(outDir);
    return Object.fromEntries(Object.entries(errors).sort(([a], [b]) => (a < b ? -1 : 1)));
}

export function loadErrorMap(path = resolve(repoRoot, "catalog/errors.json")) {
    return JSON.parse(readFileSync(path, "utf8")).errors;
}

function decodeArguments(signature, data) {
    // cast decode-calldata expects the selector in front, as revert data carries it.
    const result = spawnSync("cast", ["decode-calldata", "--json", signature, data], {
        cwd: repoRoot,
        encoding: "utf8",
    });
    if (result.status !== 0) return null;
    try {
        return JSON.parse(result.stdout).map((value) => (typeof value === "string" ? value : String(value)));
    } catch {
        return null;
    }
}

/// Decodes revert data. Never throws: an unknown selector or undecodable
/// arguments are reported as such.
///
/// Returns { kind, selector, signature, name, arguments, declaredIn, text } where
/// kind is one of "custom-error", "error-string", "panic", "unknown", "empty".
export function decodeRevert(data, errorMap) {
    const hex = typeof data === "string" ? data.trim() : "";
    if (!/^0x[0-9a-fA-F]*$/.test(hex)) {
        return {
            kind: "unknown",
            selector: null,
            signature: null,
            name: null,
            arguments: [],
            declaredIn: [],
            text: "not hex revert data",
        };
    }
    if (hex.length < 10) {
        return {
            kind: "empty",
            selector: null,
            signature: null,
            name: null,
            arguments: [],
            declaredIn: [],
            text: "reverted without data (an out-of-gas, a require without a message, or a delegatecall that reverted without data)",
        };
    }
    const selector = hex.slice(0, 10).toLowerCase();
    const payload = `0x${hex.slice(10)}`;

    if (selector === ERROR_STRING_SELECTOR) {
        const args = decodeArguments("Error(string)", hex);
        const reason = args ? args[0] : null;
        return {
            kind: "error-string",
            selector,
            signature: "Error(string)",
            name: "Error",
            arguments: args ?? [],
            declaredIn: [],
            text: reason === null ? "Error(string) with undecodable data" : `Error(${JSON.stringify(reason)})`,
        };
    }
    if (selector === PANIC_SELECTOR) {
        const args = decodeArguments("Panic(uint256)", hex);
        const code = args ? Number(args[0]) : null;
        const meaning = code === null ? "undecodable panic code" : (PANIC_CODES[code] ?? `unknown panic code ${code}`);
        return {
            kind: "panic",
            selector,
            signature: "Panic(uint256)",
            name: "Panic",
            arguments: args ?? [],
            declaredIn: [],
            text: `Panic(0x${(code ?? 0).toString(16).padStart(2, "0")}): ${meaning}`,
        };
    }

    const known = errorMap?.[selector];
    if (!known) {
        return {
            kind: "unknown",
            selector,
            signature: null,
            name: null,
            arguments: [],
            declaredIn: [],
            text: `${selector} is not a custom error of this repository's contracts (${(hex.length - 10) / 2} bytes of data)`,
        };
    }
    const args = known.inputs.length === 0 ? [] : decodeArguments(known.signature, hex);
    if (args === null) {
        return {
            kind: "custom-error",
            selector,
            signature: known.signature,
            name: known.name,
            arguments: [],
            declaredIn: known.declaredIn,
            text: `${known.signature} with undecodable arguments`,
        };
    }
    const rendered = known.inputs
        .map((input, index) => `${input.name ? `${input.name}: ` : ""}${args[index]}`)
        .join(", ");
    return {
        kind: "custom-error",
        selector,
        signature: known.signature,
        name: known.name,
        arguments: args,
        declaredIn: known.declaredIn,
        text: `${known.name}(${rendered})`,
    };
}

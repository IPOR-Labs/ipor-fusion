// Reads the parts of a Solidity fuse that the integration catalog describes:
// the struct behind an enter/exit/claim call, or the plain parameter list when
// the function takes no struct, and the canonical ABI tuple of either.
//
// It is a line-oriented reader, not a compiler. It understands what the fuses
// in this repository write — one field per line, nested structs, enums,
// contract-typed fields and fixed or dynamic arrays of those — and stops with
// a named error on anything else rather than guessing a selector.

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, relative, resolve } from "node:path";

export class SolidityReadError extends Error {
    constructor(code, message) {
        super(message);
        this.code = code;
    }
}

const elementary =
    /^(address|bool|string|bytes|bytes(?:[1-9]|[12][0-9]|3[0-2])|u?int(?:8|16|24|32|40|48|56|64|72|80|88|96|104|112|120|128|136|144|152|160|168|176|184|192|200|208|216|224|232|240|248|256)?)$/;

/// Splits "Type[]", "Type[3]" and "Type" into the base type and its array suffix.
function splitArray(type) {
    const match = /^(.*?)((?:\[\d*\])*)$/.exec(type);
    return { base: match[1], suffix: match[2] };
}

/// Reads one struct declaration: field types, names and the line it starts on.
export function parseStruct(source, path, name) {
    const lines = source.split("\n");
    const start = lines.findIndex((line) => new RegExp(`^\\s*struct\\s+${name}\\s*\\{`).test(line));
    if (start === -1) throw new SolidityReadError("STRUCT_NOT_FOUND", `${name} is not declared in ${path}`);
    const fields = [];
    for (let index = start + 1; index < lines.length; index += 1) {
        const line = lines[index].trim();
        if (line.startsWith("}")) {
            return { struct: name, declaredAtLine: start + 1, fields };
        }
        if (line === "" || line.startsWith("//") || line.startsWith("/*") || line.startsWith("*")) continue;
        const match = /^([A-Za-z_][A-Za-z0-9_.]*(?:\[\d*\])*)\s+(?:payable\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*;/.exec(line);
        if (!match) throw new SolidityReadError("STRUCT_UNPARSEABLE", `${path}:${index + 1} in ${name}: "${line}"`);
        fields.push({ type: match[1], name: match[2], line: index + 1 });
    }
    throw new SolidityReadError("STRUCT_UNPARSEABLE", `${name} in ${path} is not closed`);
}

/// Reads the parameter list of `function <name>(...)`: types, names and the
/// line the function starts on. Used when a fuse takes plain values instead of
/// a struct, including a function with no parameters at all.
export function parseFunctionParams(source, path, name) {
    const lines = source.split("\n");
    const start = lines.findIndex((line) => new RegExp(`^\\s*function\\s+${name}\\s*\\(`).test(line));
    if (start === -1) throw new SolidityReadError("FUNCTION_NOT_FOUND", `function ${name} is not declared in ${path}`);
    // Collect text from the opening parenthesis to its matching close.
    let text = "";
    let depth = 0;
    let opened = false;
    let endLine = start;
    for (let index = start; index < lines.length; index += 1) {
        const line = lines[index].replace(/\/\/.*$/, "");
        for (const char of line) {
            if (char === "(") {
                depth += 1;
                if (!opened) {
                    opened = true;
                    continue;
                }
            }
            if (char === ")") {
                depth -= 1;
                if (opened && depth === 0) {
                    endLine = index;
                    break;
                }
            }
            if (opened) text += char;
        }
        if (opened && depth === 0) break;
        text += " ";
    }
    if (!opened || depth !== 0) {
        throw new SolidityReadError(
            "FUNCTION_UNPARSEABLE",
            `function ${name} in ${path} has an unbalanced parameter list`,
        );
    }
    const fields = [];
    for (const raw of text.split(",")) {
        const param = raw.trim();
        if (param === "") continue;
        const match =
            /^([A-Za-z_][A-Za-z0-9_.]*(?:\[\d*\])*)(?:\s+(?:memory|calldata|storage|payable))*(?:\s+([A-Za-z_][A-Za-z0-9_]*))?$/.exec(
                param,
            );
        if (!match) {
            throw new SolidityReadError(
                "FUNCTION_UNPARSEABLE",
                `${path}:${start + 1} function ${name}: parameter "${param}"`,
            );
        }
        fields.push({ type: match[1], name: match[2] ?? "", line: start + 1 });
    }
    return { declaredAtLine: start + 1, endLine: endLine + 1, fields };
}

/// Remappings from foundry.toml, longest prefix first.
let remappingsCache = null;
function remappings(repoRoot) {
    if (remappingsCache) return remappingsCache;
    const toml = readFileSync(resolve(repoRoot, "foundry.toml"), "utf8");
    const block = /remappings\s*=\s*\[([^\]]*)\]/.exec(toml);
    remappingsCache = (block ? [...block[1].matchAll(/['"]([^'"]+)=([^'"]+)['"]/g)] : [])
        .map((match) => ({ from: match[1], to: match[2] }))
        .sort((a, b) => b.from.length - a.from.length);
    return remappingsCache;
}

/// Files a source imports, as repository-relative paths, following foundry's
/// remappings and the `libs` directories for bare package paths.
function importsOf(repoRoot, source, path) {
    const files = [];
    for (const match of source.matchAll(/import\s+(?:\{[^}]*\}\s+from\s+)?["']([^"']+)["']/g)) {
        let target = match[1];
        const remap = remappings(repoRoot).find((entry) => target.startsWith(entry.from));
        if (remap) target = `${remap.to}${target.slice(remap.from.length)}`;
        const candidates = target.startsWith(".")
            ? [resolve(repoRoot, dirname(path), target)]
            : [resolve(repoRoot, target), resolve(repoRoot, "node_modules", target), resolve(repoRoot, "lib", target)];
        const found = candidates.find((candidate) => existsSync(candidate));
        if (found) files.push(relative(repoRoot, found));
    }
    return files;
}

const declarationKinds = "struct|enum|contract|interface|library|abstract\\s+contract|type";

function declarationIn(source, name) {
    const match = new RegExp(`^\\s*(${declarationKinds})\\s+${name}\\b(?:\\s+is\\s+([A-Za-z0-9]+))?`, "m").exec(source);
    if (!match) return null;
    return { kind: match[1].replace(/^abstract\s+/, ""), underlying: match[2] ?? null };
}

/// Finds where a user-defined type (struct, enum, contract, interface,
/// library, user-defined value type) is declared: in the file the fuse is read
/// from, then in the files it imports (transitively, imports first), and as a
/// last resort anywhere under contracts/ or lib/ provided the hit is unique.
function findDeclaration(repoRoot, preferredSource, preferredPath, name) {
    const visited = new Set();
    const queue = [{ path: preferredPath, source: preferredSource }];
    while (queue.length > 0) {
        const { path, source } = queue.shift();
        if (visited.has(path)) continue;
        visited.add(path);
        const declaration = declarationIn(source, name);
        if (declaration) return { ...declaration, path, source };
        for (const file of importsOf(repoRoot, source, path)) {
            if (!visited.has(file)) queue.push({ path: file, source: readFileSync(resolve(repoRoot, file), "utf8") });
        }
    }

    const result = spawnSync(
        "rg",
        ["-l", "--glob", "*.sol", "-e", `^\\s*(${declarationKinds})\\s+${name}\\b`, "contracts", "lib"],
        { cwd: repoRoot, encoding: "utf8" },
    );
    const hits = [];
    for (const file of (result.stdout ?? "").split("\n").filter(Boolean).sort()) {
        const source = readFileSync(resolve(repoRoot, file), "utf8");
        const declaration = declarationIn(source, name);
        if (declaration) hits.push({ ...declaration, path: file, source });
    }
    if (hits.length === 0) {
        throw new SolidityReadError(
            "TYPE_NOT_FOUND",
            `type ${name} used in ${preferredPath} is not declared in that file, its imports, or anywhere under contracts/ or lib/`,
        );
    }
    if (hits.length > 1) {
        throw new SolidityReadError(
            "TYPE_AMBIGUOUS",
            `type ${name} used in ${preferredPath} is not imported and is declared in more than one place: ${hits.map((hit) => hit.path).join(", ")}`,
        );
    }
    return hits[0];
}

/// Canonical ABI type of a declared Solidity type: structs become tuples,
/// enums uint8, contracts and interfaces address, `Lib.Type` is resolved by
/// its last segment.
export function canonicalType(repoRoot, source, path, declared, seen = []) {
    const { base, suffix } = splitArray(declared);
    if (elementary.test(base)) return `${base === "uint" ? "uint256" : base === "int" ? "int256" : base}${suffix}`;
    const name = base.split(".").pop();
    if (seen.includes(name)) throw new SolidityReadError("TYPE_RECURSIVE", `type ${name} refers to itself`);
    const declaration = findDeclaration(repoRoot, source, path, name);
    if (declaration.kind === "enum") return `uint8${suffix}`;
    if (declaration.kind === "type") {
        if (!elementary.test(declaration.underlying ?? "")) {
            throw new SolidityReadError(
                "TYPE_UNSUPPORTED",
                `user-defined value type ${name} wraps ${declaration.underlying}`,
            );
        }
        return `${declaration.underlying}${suffix}`;
    }
    if (declaration.kind !== "struct") return `address${suffix}`;
    const parsed = parseStruct(declaration.source, declaration.path, name);
    const inner = parsed.fields.map((field) =>
        canonicalType(repoRoot, declaration.source, declaration.path, field.type, [...seen, name]),
    );
    return `(${inner.join(",")})${suffix}`;
}

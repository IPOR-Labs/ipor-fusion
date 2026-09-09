#!/usr/bin/env node
// Writes catalog/errors.json: every custom error the contracts under contracts/
// compile to, keyed by selector, from the forge artifacts under out/.
//
// Usage:
//   node tools/generate-error-map.mjs [--check] [--out <dir>] [--source-root <dir>] [errors.json]
//
// --out names the artifact directory (default out/); --source-root the checkout
// whose contracts/ the artifacts were compiled from (default this repository).
//
// Exit codes: 0 written (or up to date with --check), 1 out of date with
// --check, 2 no artifacts to read (run `forge build` first).

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { relative, resolve } from "node:path";
import { collectErrors } from "./lib/revert-decoder.mjs";

const repoRoot = resolve(import.meta.dirname, "..");
const args = process.argv.slice(2);
const check = args.includes("--check");
const option = (flag, fallback) => {
    const index = args.indexOf(flag);
    return index === -1 ? fallback : resolve(args[index + 1]);
};
const outDir = option("--out", resolve(repoRoot, "out"));
const sourceRoot = option("--source-root", repoRoot);
const valueIndexes = new Set(
    ["--out", "--source-root"].map((flag) => args.indexOf(flag) + 1).filter((index) => index > 0),
);
const positional = args.filter((arg, index) => !arg.startsWith("--") && !valueIndexes.has(index));
const mapPath = resolve(positional[0] ?? resolve(repoRoot, "catalog/errors.json"));

const errors = collectErrors(outDir, { sourceRoot });
if (errors === null || Object.keys(errors).length === 0) {
    console.error(
        `errors:generate: NO_ARTIFACTS: ${relative(repoRoot, outDir)} holds no compiled contracts; run forge build`,
    );
    process.exit(2);
}

const document = {
    schemaVersion: 1,
    description:
        "Custom errors of the contracts under contracts/, keyed by 4-byte selector, read from the forge artifacts. Regenerate with npm run errors:generate after a contract change; npm run errors:check fails when this file is stale.",
    generator: "tools/generate-error-map.mjs",
    count: Object.keys(errors).length,
    errors,
};
const serialized = `${JSON.stringify(document, null, 4)}\n`;

if (check) {
    const onDisk = existsSync(mapPath) ? readFileSync(mapPath, "utf8") : "";
    if (onDisk !== serialized) {
        console.error(
            `errors:generate: OUT_OF_DATE: ${relative(repoRoot, mapPath)} does not match the artifacts; run npm run errors:generate`,
        );
        process.exit(1);
    }
    console.log(`error map is up to date with the artifacts (${document.count} error(s))`);
} else {
    writeFileSync(mapPath, serialized);
    console.log(`wrote ${relative(repoRoot, mapPath)} (${document.count} error(s))`);
}

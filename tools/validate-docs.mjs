#!/usr/bin/env node
// Checks that the documentation this repository ships still points at things
// that exist.
//
// Usage:
//   node tools/validate-docs.mjs [file.md ...]
//
// Exit codes: 0 valid, 1 invalid, 2 could not read an input file.
//
// Scope: the documentation this repository ships — docs/, the root README and
// every AGENTS.md — plus evals/, taken from the files git would keep (tracked,
// or untracked and not ignored). Private, ignored notes under docs/ are none of
// this check's business, and agent-readiness/tasks/ holds per-task process logs
// that quote paths as prose rather than linking them.
// External links are listed, never fetched: this must work offline.

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import { dirname, relative, resolve } from "node:path";

const repoRoot = resolve(import.meta.dirname, "..");

function gitFiles() {
    const result = spawnSync("git", ["ls-files", "--cached", "--others", "--exclude-standard"], {
        cwd: repoRoot,
        encoding: "utf8",
    });
    if (result.status !== 0) {
        console.error("validate:docs: GIT_UNAVAILABLE: could not list files with git");
        process.exit(2);
    }
    return result.stdout.split("\n").filter(Boolean);
}

const shipped = [/^docs\//, /^README\.md$/, /(^|\/)AGENTS\.md$/, /^evals\//];
const inputs =
    process.argv.length > 2
        ? process.argv.slice(2).map((path) => relative(repoRoot, resolve(path)))
        : gitFiles().filter((path) => path.endsWith(".md") && shipped.some((pattern) => pattern.test(path)));

const errors = [];
const fail = (where, message) => errors.push(`${where}: ${message}`);
let links = 0;
let external = 0;

// [text](target) and bare <target>, ignoring images' leading ! only for clarity.
const linkPattern = /\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g;

for (const file of inputs) {
    const absolute = resolve(repoRoot, file);
    if (!existsSync(absolute)) {
        console.error(`validate:docs: UNREADABLE: ${file}`);
        process.exit(2);
    }
    const text = readFileSync(absolute, "utf8");
    // Fenced code blocks hold example commands, not links to check.
    const withoutCode = text.replace(/```[\s\S]*?```/g, "");

    for (const match of withoutCode.matchAll(linkPattern)) {
        const target = match[1];
        links += 1;
        if (/^(https?:|mailto:|#)/.test(target)) {
            external += 1;
            continue;
        }
        const [path, anchor] = target.split("#");
        if (!path) continue;
        const resolved = resolve(dirname(absolute), path);
        if (!existsSync(resolved)) {
            fail(file, `link target does not exist: ${target}`);
            continue;
        }
        if (anchor && statSync(resolved).isFile() && resolved.endsWith(".md")) {
            // Anchors are checked against the target's own headings.
            const headings = readFileSync(resolved, "utf8")
                .split("\n")
                .filter((line) => line.startsWith("#"))
                .map((line) =>
                    line
                        .replace(/^#+\s*/, "")
                        .toLowerCase()
                        .replace(/[^a-z0-9\s-]/g, "")
                        .trim()
                        .replace(/\s+/g, "-"),
                );
            if (!headings.includes(anchor.toLowerCase())) {
                fail(file, `anchor "#${anchor}" is not a heading in ${path}`);
            }
        }
    }
}

if (errors.length > 0) {
    console.error("invalid documentation references:");
    for (const error of errors) console.error(`  ${error}`);
    process.exit(1);
}

console.log(
    `valid documentation references: ${inputs.length} file(s), ${links - external} local link(s) checked, ${external} external link(s) listed and not fetched`,
);

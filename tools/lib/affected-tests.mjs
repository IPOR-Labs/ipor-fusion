import { existsSync, readFileSync } from "node:fs";
import { dirname, relative, resolve, sep } from "node:path";

const documentationOnly = [
    /^docs\//,
    /(^|\/)AGENTS\.md$/,
    /^README\.md$/,
    /^CLAUDE\.md$/,
    /^\.gitignore$/,
];

const highRisk = [
    /^contracts\/libraries\//,
    /^contracts\/vaults\//,
    /^contracts\/managers\/access\//,
    /^contracts\/managers\/price\//,
    /^contracts\/price_oracle\//,
];

const factoryBoundary = [/^contracts\/factory\//, /^contracts\/managers\/fee\/FeeManagerFactory\.sol$/];

const catalogTooling = [
    /^config\/test-suites(?:\.schema)?\.json$/,
    /^tools\/(?:validate-test-suites|run-unit-tests|run-fork-tests|run-affected-tests)\.mjs$/,
    /^tools\/lib\/affected-tests\.mjs$/,
];

function normalize(path) {
    return path.split(sep).join("/").replace(/^\.\//, "");
}

function relativeImports(path, repoRoot) {
    const source = readFileSync(resolve(repoRoot, path), "utf8");
    const imports = [];
    const expression = /\bimport\s+(?:[^;]*?\sfrom\s+)?["']([^"']+)["']\s*;/gs;
    for (const match of source.matchAll(expression)) {
        if (!match[1].startsWith(".")) continue;
        const absolute = resolve(repoRoot, dirname(path), match[1]);
        const resolved = normalize(relative(repoRoot, absolute));
        if (!resolved.startsWith("../") && existsSync(absolute)) imports.push(resolved);
    }
    return imports;
}

function dependencies(entry, repoRoot, cache = new Map(), visiting = new Set()) {
    if (cache.has(entry)) return cache.get(entry);
    if (visiting.has(entry) || !existsSync(resolve(repoRoot, entry))) return new Set();
    visiting.add(entry);
    const result = new Set([entry]);
    for (const imported of relativeImports(entry, repoRoot)) {
        for (const dependency of dependencies(imported, repoRoot, cache, visiting)) result.add(dependency);
    }
    visiting.delete(entry);
    cache.set(entry, result);
    return result;
}

export function selectAffected({ changedPaths, catalog, repoRoot }) {
    const changed = [...new Set(changedPaths.map(normalize))].sort();
    const selected = new Set();
    const reasons = [];
    const recognized = new Set();
    const dependencyCache = new Map();
    const suiteDependencies = new Map(
        catalog.suites.map((suite) => [suite.id, dependencies(suite.path, repoRoot, dependencyCache)]),
    );

    const selectAll = (reason, path) => {
        for (const suite of catalog.suites) selected.add(suite.id);
        reasons.push({ path, scope: "all-classified", reason });
        recognized.add(path);
    };

    for (const path of changed) {
        if (documentationOnly.some((pattern) => pattern.test(path))) {
            reasons.push({ path, scope: "validation-only", reason: "documentation or process metadata" });
            recognized.add(path);
            continue;
        }
        if (highRisk.some((pattern) => pattern.test(path))) {
            selectAll("shared storage, vault, access or oracle boundary", path);
            continue;
        }
        if (factoryBoundary.some((pattern) => pattern.test(path))) {
            selectAll("factory trust boundary includes local and fork suites", path);
            continue;
        }
        if (catalogTooling.some((pattern) => pattern.test(path))) {
            selectAll("test catalog or runner behavior changed", path);
            continue;
        }

        const importers = catalog.suites.filter((suite) => suiteDependencies.get(suite.id).has(path));
        if (importers.length > 0) {
            for (const suite of importers) selected.add(suite.id);
            reasons.push({
                path,
                scope: "importers",
                reason: `imported by ${importers.map((suite) => suite.id).join(", ")}`,
            });
            recognized.add(path);
        }
    }

    for (const path of changed) {
        if (!recognized.has(path)) selectAll("unclassified or unknown dependency; widened conservatively", path);
    }

    return {
        changedPaths: changed,
        selectedIds: catalog.suites.filter((suite) => selected.has(suite.id)).map((suite) => suite.id),
        reasons,
    };
}

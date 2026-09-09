import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { test } from "node:test";

const repoRoot = resolve(import.meta.dirname, "..");
const generator = resolve(repoRoot, "tools/generate-catalog.mjs");
const validator = resolve(repoRoot, "tools/validate-catalog.mjs");
const catalog = resolve(repoRoot, "catalog/fuses.json");
const actionFuse = "contracts/fuses/erc4626/Erc4626SupplyFuse.sol";

function run(script, args) {
    return spawnSync(process.execPath, [script, ...args], { cwd: repoRoot, encoding: "utf8" });
}

/// A scratch copy of the catalog whose action fuse is a copy of the real source,
/// so that a struct can be changed without touching the repository.
function scratch(changeSource = (text) => text) {
    const directory = mkdtempSync(resolve(tmpdir(), "fusion-catalog-generate-"));
    const sourcePath = resolve(directory, "Erc4626SupplyFuse.sol");
    writeFileSync(sourcePath, changeSource(readFileSync(resolve(repoRoot, actionFuse), "utf8")));
    const value = JSON.parse(readFileSync(catalog, "utf8"));
    value.integrations[0].source.actionFuse = sourcePath;
    const path = resolve(directory, "fuses.json");
    writeFileSync(path, `${JSON.stringify(value, null, 4)}\n`);
    return { directory, path, sourcePath };
}

test("the committed catalog is up to date with the sources", () => {
    const result = run(generator, ["--check"]);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /up to date with the sources/);
});

test("regenerating is deterministic", () => {
    const { directory, path } = scratch();
    try {
        assert.equal(run(generator, [path]).status, 0);
        const first = readFileSync(path, "utf8");
        const second = run(generator, [path]);
        assert.equal(second.status, 0);
        assert.match(second.stdout, /unchanged/);
        assert.equal(readFileSync(path, "utf8"), first);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("changing a struct changes the generated data and is caught by --check", () => {
    const { directory, path } = scratch((text) =>
        text.replace("uint256 minSharesOut;", "uint256 minSharesOut;\n    address recipient;"),
    );
    try {
        assert.equal(run(generator, [path]).status, 0);
        const generated = JSON.parse(readFileSync(path, "utf8")).integrations[0].interface.generated;
        assert.equal(generated.operations.enter.signature, "enter((address,uint256,uint256,address))");
        assert.notEqual(generated.operations.enter.selector, "0x41b11ae7");
        assert.deepEqual(
            generated.operations.enter.fields.map((field) => field.name),
            ["vault", "vaultAssetAmount", "minSharesOut", "recipient"],
        );

        // A field added in Solidity and not described in the catalog is an error.
        const invalid = run(validator, [path]);
        assert.equal(invalid.status, 1);
        assert.match(invalid.stderr, /interface\.enter\.fields.*described .* but the struct is /);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("--check reports a catalog that no longer matches its sources", () => {
    const { directory, path } = scratch();
    try {
        assert.equal(run(generator, [path]).status, 0);
        const value = JSON.parse(readFileSync(path, "utf8"));
        value.integrations[0].interface.generated.operations.enter.selector = "0xdeadbeef";
        writeFileSync(path, `${JSON.stringify(value, null, 4)}\n`);

        const stale = run(generator, ["--check", path]);
        assert.equal(stale.status, 1);
        assert.match(stale.stderr, /OUT_OF_DATE/);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("editorial content is never overwritten by the generator", () => {
    const { directory, path } = scratch();
    try {
        const before = JSON.parse(readFileSync(path, "utf8")).integrations[0];
        before.interface.enter.fields[0].meaning = "an edited meaning that the generator must keep";
        before.substrates.meaning = "an edited substrate description";
        before.deployments.actionFuse.notes.push("an editorial note");
        const value = JSON.parse(readFileSync(path, "utf8"));
        value.integrations[0] = before;
        writeFileSync(path, `${JSON.stringify(value, null, 4)}\n`);

        assert.equal(run(generator, [path]).status, 0);
        const after = JSON.parse(readFileSync(path, "utf8")).integrations[0];
        assert.equal(after.interface.enter.fields[0].meaning, "an edited meaning that the generator must keep");
        assert.equal(after.substrates.meaning, "an edited substrate description");
        assert.deepEqual(after.deployments, before.deployments);
        assert.deepEqual(after.roles, before.roles);
        assert.deepEqual(after.valuation, before.valuation);
        assert.deepEqual(after.tests, before.tests);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("a struct the catalog names but Solidity does not declare is a named failure", () => {
    const { directory, path } = scratch((text) => text.replace("struct Erc4626SupplyFuseExitData", "struct Renamed"));
    try {
        const result = run(generator, [path]);
        assert.equal(result.status, 2);
        assert.match(result.stderr, /STRUCT_NOT_FOUND: Erc4626SupplyFuseExitData/);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

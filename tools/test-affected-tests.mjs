import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { test } from "node:test";
import { selectAffected } from "./lib/affected-tests.mjs";

const repoRoot = resolve(import.meta.dirname, "..");
const catalog = JSON.parse(readFileSync(resolve(repoRoot, "config/test-suites.json"), "utf8"));
const allIds = catalog.suites.map((suite) => suite.id);

function select(changedPaths) {
    return selectAffected({ changedPaths, catalog, repoRoot });
}

test("a factory change selects every local and fork factory pilot suite", () => {
    assert.deepEqual(select(["contracts/factory/FusionFactory.sol"]).selectedIds, allIds);
});

test("a shared storage, access or oracle change widens to all classified suites", () => {
    for (const path of [
        "contracts/libraries/PlasmaVaultStorageLib.sol",
        "contracts/managers/access/AccessManager.sol",
        "contracts/price_oracle/PriceOracleMiddleware.sol",
    ]) {
        assert.deepEqual(select([path]).selectedIds, allIds);
    }
});

test("an unclassified test or unknown helper widens conservatively and says why", () => {
    for (const path of ["test/fuses/example/Example.t.sol", "test/test_helpers/UnknownHelper.sol"]) {
        const result = select([path]);
        assert.deepEqual(result.selectedIds, allIds);
        assert.match(result.reasons.at(-1).reason, /widened conservatively/);
    }
});

test("documentation-only changes select validation only", () => {
    const result = select(["docs/testing.md", "README.md"]);
    assert.deepEqual(result.selectedIds, []);
    assert.ok(result.reasons.every((reason) => reason.scope === "validation-only"));
});

test("the Solidity import graph selects the suite that transitively imports a helper", () => {
    const directory = mkdtempSync(resolve(tmpdir(), "fusion-affected-"));
    try {
        mkdirSync(resolve(directory, "test"));
        mkdirSync(resolve(directory, "contracts"));
        writeFileSync(resolve(directory, "contracts/Helper.sol"), "pragma solidity 0.8.30;\\n");
        writeFileSync(resolve(directory, "test/A.t.sol"), 'import "../contracts/Helper.sol";\\n');
        writeFileSync(resolve(directory, "test/B.t.sol"), "pragma solidity 0.8.30;\\n");
        const synthetic = {
            suites: [
                { id: "a", path: "test/A.t.sol" },
                { id: "b", path: "test/B.t.sol" },
            ],
        };
        const result = selectAffected({
            changedPaths: ["contracts/Helper.sol"],
            catalog: synthetic,
            repoRoot: directory,
        });
        assert.deepEqual(result.selectedIds, ["a"]);
        assert.equal(result.reasons[0].scope, "importers");
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

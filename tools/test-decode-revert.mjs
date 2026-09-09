import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { test } from "node:test";
import { selector } from "./lib/keccak.mjs";
import { collectErrors, decodeRevert, loadErrorMap } from "./lib/revert-decoder.mjs";

const repoRoot = resolve(import.meta.dirname, "..");
const generator = resolve(repoRoot, "tools/generate-error-map.mjs");
const cli = resolve(repoRoot, "tools/decode-revert.mjs");

function encode(signature, ...args) {
    const types = signature.slice(signature.indexOf("("));
    const result = spawnSync("cast", ["abi-encode", `f${types}`, ...args], { cwd: repoRoot, encoding: "utf8" });
    assert.equal(result.status, 0, result.stderr);
    return `${selector(signature)}${result.stdout.trim().slice(2)}`;
}

function run(script, args) {
    return spawnSync(process.execPath, [script, ...args], { cwd: repoRoot, encoding: "utf8" });
}

const errorMap = loadErrorMap();

test("the committed map holds the errors the pilot path reverts with", () => {
    for (const signature of [
        "MarketLimitExceeded(uint256,uint256,uint256)",
        "AccountIsLocked(uint256)",
        "AccessManagedUnauthorized(address)",
        "Erc4626SupplyFuseUnsupportedVault(string,address)",
        "FailedInnerCall()",
        "UnsupportedAsset()",
    ]) {
        assert.equal(errorMap[selector(signature)]?.signature, signature, `${signature} is missing`);
    }
    assert.deepEqual(errorMap[selector("MarketLimitExceeded(uint256,uint256,uint256)")].declaredIn, [
        "contracts/libraries/AssetDistributionProtectionLib.sol",
    ]);
    // Inherited from OpenZeppelin and never redeclared here: known, but declared in no repository file.
    assert.deepEqual(errorMap[selector("FailedInnerCall()")].declaredIn, []);
    // Redeclared by the access manager, so the repository file is named.
    assert.deepEqual(errorMap[selector("AccessManagedUnauthorized(address)")].declaredIn, [
        "contracts/managers/access/IporFusionAccessManager.sol",
    ]);
});

test("a custom error with arguments is named with its field names", () => {
    const data = encode("MarketLimitExceeded(uint256,uint256,uint256)", "100001", "59999999999", "49999999999");
    const decoded = decodeRevert(data, errorMap);
    assert.equal(decoded.kind, "custom-error");
    assert.equal(decoded.name, "MarketLimitExceeded");
    assert.deepEqual(decoded.arguments, ["100001", "59999999999", "49999999999"]);
    assert.equal(
        decoded.text,
        "MarketLimitExceeded(marketId: 100001, balanceInMarket: 59999999999, limit: 49999999999)",
    );
});

test("a custom error without arguments, Error(string) and Panic(uint256)", () => {
    assert.equal(decodeRevert(selector("FailedInnerCall()"), errorMap).text, "FailedInnerCall()");
    const reason = decodeRevert(encode("Error(string)", "insufficient balance"), errorMap);
    assert.equal(reason.kind, "error-string");
    assert.equal(reason.text, 'Error("insufficient balance")');
    const panic = decodeRevert(encode("Panic(uint256)", "17"), errorMap);
    assert.equal(panic.kind, "panic");
    assert.equal(panic.text, "Panic(0x11): arithmetic overflow or underflow outside unchecked");
});

test("empty data, an unknown selector and malformed arguments are reported, not guessed", () => {
    assert.equal(decodeRevert("0x", errorMap).kind, "empty");
    assert.equal(decodeRevert(null, errorMap).kind, "unknown");
    const unknown = decodeRevert("0xdeadbeef00", errorMap);
    assert.equal(unknown.kind, "unknown");
    assert.match(unknown.text, /0xdeadbeef is not a custom error/);
    const truncated = decodeRevert(`${selector("MarketLimitExceeded(uint256,uint256,uint256)")}00`, errorMap);
    assert.equal(truncated.kind, "custom-error");
    assert.match(truncated.text, /undecodable arguments/);
});

test("the CLI decodes --data and prints one line or JSON", () => {
    const data = encode("AccountIsLocked(uint256)", "1788932915");
    const line = run(cli, ["--data", data]);
    assert.equal(line.status, 0, line.stderr);
    assert.equal(
        line.stdout.trim(),
        "AccountIsLocked(unlockTime: 1788932915) [contracts/managers/access/RedemptionDelayLib.sol]",
    );
    const json = run(cli, ["--data", data, "--json"]);
    assert.equal(JSON.parse(json.stdout).name, "AccountIsLocked");
    const bad = run(cli, ["--tx", "0xabc"]);
    assert.equal(bad.status, 2);
    assert.match(bad.stderr, /INVALID_ARGUMENT/);
});

/// A scratch out/ with one artifact whose compilation target is under contracts/
/// and one that is not; only the first contributes errors.
function scratchArtifacts() {
    const directory = mkdtempSync(resolve(tmpdir(), "fusion-errors-"));
    const artifact = (target, name, errors) => ({
        abi: errors.map(([errorName, inputs]) => ({ type: "error", name: errorName, inputs })),
        metadata: { settings: { compilationTarget: { [target]: name } } },
    });
    mkdirSync(resolve(directory, "out/Own.sol"), { recursive: true });
    mkdirSync(resolve(directory, "out/Dep.sol"), { recursive: true });
    // The source the artifact was compiled from, so the directory is read and the declaration found.
    mkdirSync(resolve(directory, "contracts"), { recursive: true });
    writeFileSync(resolve(directory, "contracts/Own.sol"), "contract Own {\n    error OwnError(address who);\n}\n");
    writeFileSync(
        resolve(directory, "out/Own.sol/Own.json"),
        JSON.stringify(
            artifact("contracts/Own.sol", "Own", [
                ["OwnError", [{ name: "who", type: "address" }]],
                [
                    "Nested",
                    [
                        {
                            name: "key",
                            type: "tuple",
                            components: [
                                { name: "a", type: "address" },
                                { name: "b", type: "uint24" },
                            ],
                        },
                    ],
                ],
            ]),
        ),
    );
    writeFileSync(
        resolve(directory, "out/Dep.sol/Dep.json"),
        JSON.stringify(artifact("lib/dep/Dep.sol", "Dep", [["DepError", []]])),
    );
    return directory;
}

test("the map is built from contracts/ artifacts only, with canonical tuple types", () => {
    const directory = scratchArtifacts();
    try {
        const errors = collectErrors(resolve(directory, "out"), { sourceRoot: directory });
        assert.deepEqual(
            Object.keys(errors).sort(),
            [selector("Nested((address,uint24))"), selector("OwnError(address)")].sort(),
        );
        assert.equal(errors[selector("Nested((address,uint24))")].inputs[0].type, "(address,uint24)");
        assert.deepEqual(errors[selector("OwnError(address)")].declaredIn, ["contracts/Own.sol"]);
        // Nested is in the artifact but declared in no source under contracts/ (inherited).
        assert.deepEqual(errors[selector("Nested((address,uint24))")].declaredIn, []);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("errors:generate is deterministic and --check reports a stale map", () => {
    const directory = scratchArtifacts();
    try {
        const mapPath = resolve(directory, "errors.json");
        const common = ["--out", resolve(directory, "out"), "--source-root", directory];
        assert.equal(run(generator, [...common, mapPath]).status, 0);
        const first = readFileSync(mapPath, "utf8");
        assert.equal(run(generator, [...common, mapPath]).status, 0);
        assert.equal(readFileSync(mapPath, "utf8"), first);
        assert.equal(run(generator, ["--check", ...common, mapPath]).status, 0);
        writeFileSync(mapPath, first.replace("OwnError", "Renamed"));
        const stale = run(generator, ["--check", ...common, mapPath]);
        assert.equal(stale.status, 1);
        assert.match(stale.stderr, /OUT_OF_DATE/);
        const empty = run(generator, ["--out", resolve(directory, "nowhere"), "--source-root", directory, mapPath]);
        assert.equal(empty.status, 2);
        assert.match(empty.stderr, /NO_ARTIFACTS/);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

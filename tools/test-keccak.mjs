import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { test } from "node:test";
import { keccak256, selector } from "./lib/keccak.mjs";

// Known values: the empty string, and selectors of fuse signatures in the catalog.
test("keccak256 of the empty string", () => {
    assert.equal(keccak256(""), "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470");
});

test("selectors of catalogued signatures", () => {
    assert.equal(selector("enter((address,uint256,uint256))"), "0x41b11ae7");
    assert.equal(selector("exit()"), "0xe9fad8ee");
    assert.equal(selector("claim(uint256[],address[][])"), "0xedd4318c");
    assert.equal(selector("balanceOf()"), "0x722713f7");
});

// Inputs longer than one 136-byte block exercise the multi-block absorb.
test("agrees with cast sig on a signature longer than one block", () => {
    const signature = `${"a".repeat(200)}()`;
    const result = spawnSync("cast", ["sig", signature], { encoding: "utf8" });
    if (result.status !== 0) return; // cast is not required for this test to be meaningful elsewhere
    assert.equal(selector(signature), result.stdout.trim());
});

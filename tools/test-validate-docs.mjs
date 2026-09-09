import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import { test } from "node:test";

const repoRoot = resolve(import.meta.dirname, "..");
const validator = resolve(repoRoot, "tools/validate-docs.mjs");

function run(...args) {
    return spawnSync(process.execPath, [validator, ...args], { cwd: repoRoot, encoding: "utf8" });
}

function scratchDoc(content) {
    const directory = mkdtempSync(resolve(tmpdir(), "fusion-docs-"));
    const path = resolve(directory, "page.md");
    writeFileSync(path, content);
    return { directory, path };
}

test("the shipped documentation passes", () => {
    const result = run();
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /valid documentation references: \d+ file\(s\)/);
    assert.match(result.stdout, /external link\(s\) listed and not fetched/);
});

test("a broken relative link fails", () => {
    const { directory, path } = scratchDoc("# Page\n\nSee [the plan](./does-not-exist.md).\n");
    try {
        const result = run(path);
        assert.equal(result.status, 1);
        assert.match(result.stderr, /link target does not exist: \.\/does-not-exist\.md/);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("a link to a missing ABI or manifest fails", () => {
    const { directory, path } = scratchDoc(
        "# Page\n\nThe ABI is [here](../abi/fusion-factory-ethereum-0xdeadbeef/FusionFactory.abi.json).\n",
    );
    try {
        const result = run(path);
        assert.equal(result.status, 1);
        assert.match(result.stderr, /link target does not exist/);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("an anchor that is not a heading in the target fails", () => {
    const { directory, path } = scratchDoc(
        `# Page\n\nSee [the recipe](${resolve(repoRoot, "docs/vaults.md")}#no-such-heading).\n`,
    );
    try {
        const result = run(path);
        assert.equal(result.status, 1);
        assert.match(result.stderr, /anchor "#no-such-heading" is not a heading/);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("an anchor that is a heading passes, and external links are not fetched", () => {
    const { directory, path } = scratchDoc(
        `# Page\n\n[variants](${resolve(repoRoot, "docs/vaults.md")}#supported-variants)\n\n[external](https://example.invalid/never-fetched)\n`,
    );
    try {
        const result = run(path);
        assert.equal(result.status, 0, result.stderr);
        assert.match(result.stdout, /1 external link\(s\) listed and not fetched/);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("links inside fenced code blocks are examples, not references", () => {
    const { directory, path } = scratchDoc("# Page\n\n```bash\n# [not a link](./nowhere.md)\n```\n");
    try {
        const result = run(path);
        assert.equal(result.status, 0, result.stderr);
    } finally {
        rmSync(directory, { recursive: true, force: true });
    }
});

test("an unreadable input exits with the input error code", () => {
    const result = run(resolve(repoRoot, "docs/does-not-exist.md"));
    assert.equal(result.status, 2);
    assert.match(result.stderr, /UNREADABLE/);
});

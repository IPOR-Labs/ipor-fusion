#!/usr/bin/env node
// A minimal, read-only MCP server over this repository's deployment registry.
//
// Usage (stdio):
//   node tools/mcp-server.mjs
//
// It exposes exactly two tools, list_deployments and inspect_factory, and both
// call the same code paths the CLI does — there is no second registry and no
// second implementation. Nothing here can sign or send a transaction: the server
// reads manifests and, for inspect_factory, runs the read-only inspector.
//
// The public IPOR Fusion MCP server (fusion_address_lookup and the other
// read-only vault queries) remains the discovery source. It does not serve this
// repository's manifests, verification reports or compatibility tests, which is
// why these two tools exist; see docs/mcp.md.

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { createInterface } from "node:readline";
import { resolve } from "node:path";

const repoRoot = resolve(import.meta.dirname, "..");
const protocolVersion = "2024-11-05";

function manifests() {
    const root = resolve(repoRoot, "deployments");
    if (!existsSync(root)) return [];
    return readdirSync(root, { withFileTypes: true })
        .filter((entry) => entry.isDirectory() && /^[1-9][0-9]*$/.test(entry.name))
        .map((entry) => resolve(root, entry.name, "factories.json"))
        .filter(existsSync)
        .map((path) => JSON.parse(readFileSync(path, "utf8")));
}

const tools = [
    {
        name: "list_deployments",
        description:
            "List the factory deployments this repository registers, with their status, kind, address, implementation and verification evidence. Reads deployments/<chain-id>/factories.json; it is not a second registry.",
        inputSchema: {
            type: "object",
            properties: {
                chainId: { type: "integer", description: "Restrict to one chain. Omit for every registered chain." },
                status: {
                    type: "string",
                    enum: ["candidate", "verified", "deprecated", "unsupported"],
                    description: "Restrict to one evidence level.",
                },
            },
            additionalProperties: false,
        },
        handler: (input) => {
            const entries = [];
            for (const manifest of manifests()) {
                if (input.chainId !== undefined && manifest.chainId !== input.chainId) continue;
                for (const deployment of manifest.deployments) {
                    if (input.status !== undefined && deployment.status !== input.status) continue;
                    entries.push({
                        id: deployment.id,
                        chainId: deployment.chainId,
                        network: manifest.network,
                        kind: deployment.kind,
                        status: deployment.status,
                        address: deployment.address,
                        implementation: deployment.proxy.implementation,
                        reportedVersion: deployment.interface.reportedVersion,
                        supportedOperations: deployment.interface.supportedOperations,
                        verification: deployment.verification,
                    });
                }
            }
            return { schemaVersion: 1, count: entries.length, deployments: entries };
        },
    },
    {
        name: "inspect_factory",
        description:
            "Read a registered factory at a historical block: proxy and implementation code, ERC-1967 slot, reported version, components, timing and the fee packages effective for a caller. Runs the same read-only inspector as `npm run factory:inspect`. It cannot send a transaction.",
        inputSchema: {
            type: "object",
            properties: {
                chainId: { type: "integer" },
                deploymentId: { type: "string" },
                block: { type: "integer" },
                caller: { type: "string", pattern: "^0x[0-9a-fA-F]{40}$" },
            },
            required: ["chainId", "deploymentId", "block", "caller"],
            additionalProperties: false,
        },
        handler: (input) => {
            const result = spawnSync(
                process.execPath,
                [
                    resolve(repoRoot, "tools/inspect-factory.mjs"),
                    "--chain",
                    String(input.chainId),
                    "--deployment",
                    String(input.deploymentId),
                    "--block",
                    String(input.block),
                    "--caller",
                    String(input.caller),
                ],
                { cwd: repoRoot, encoding: "utf8" },
            );
            if (result.status !== 0) {
                // The CLI's named error codes are the contract; they are passed through.
                throw new Error(result.stderr.trim() || "factory:inspect failed");
            }
            return JSON.parse(result.stdout);
        },
    },
];

function respond(id, result) {
    process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
}

function respondError(id, code, message) {
    process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, error: { code, message } })}\n`);
}

const lines = createInterface({ input: process.stdin });
lines.on("line", (line) => {
    if (line.trim() === "") return;
    let request;
    try {
        request = JSON.parse(line);
    } catch {
        respondError(null, -32700, "parse error");
        return;
    }

    if (request.method === "initialize") {
        respond(request.id, {
            protocolVersion,
            capabilities: { tools: {} },
            serverInfo: { name: "ipor-fusion-deployments", version: "1" },
        });
        return;
    }
    if (request.method === "notifications/initialized") return;
    if (request.method === "tools/list") {
        respond(request.id, {
            tools: tools.map(({ name, description, inputSchema }) => ({ name, description, inputSchema })),
        });
        return;
    }
    if (request.method === "tools/call") {
        const tool = tools.find((entry) => entry.name === request.params?.name);
        if (!tool) {
            respondError(request.id, -32602, `unknown tool: ${request.params?.name}`);
            return;
        }
        try {
            const output = tool.handler(request.params.arguments ?? {});
            respond(request.id, {
                content: [{ type: "text", text: JSON.stringify(output, null, 4) }],
                isError: false,
            });
        } catch (error) {
            respond(request.id, { content: [{ type: "text", text: error.message }], isError: true });
        }
        return;
    }
    if (request.id !== undefined) respondError(request.id, -32601, `unsupported method: ${request.method}`);
});

// Schema lookup and validation for the machine-readable artifacts exchanged by
// the vault creation tools. Keep this module free of CLI concerns so producers,
// consumers and the standalone validator enforce exactly the same contract.

import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { validateSchema } from "./json-schema.mjs";

const repoRoot = resolve(import.meta.dirname, "../..");

export const artifactSchemaPaths = {
    "vault-creation": resolve(repoRoot, "schemas/artifacts/vault-creation-plan.schema.json"),
    "vault-creation-simulation": resolve(repoRoot, "schemas/artifacts/vault-creation-simulation.schema.json"),
    "vault-creation-preflight": resolve(repoRoot, "schemas/artifacts/vault-creation-preflight.schema.json"),
};

const schemas = new Map();

export function schemaForArtifact(kind) {
    const path = artifactSchemaPaths[kind];
    if (!path) return null;
    if (!schemas.has(kind)) schemas.set(kind, JSON.parse(readFileSync(path, "utf8")));
    return schemas.get(kind);
}

/// Returns schema findings for one artifact. `expectedKind` prevents a valid
/// artifact of another stage from being accepted by the wrong consumer.
export function validateArtifact(artifact, expectedKind = artifact?.kind) {
    if (!artifact || typeof artifact !== "object" || Array.isArray(artifact)) {
        return ["$: expected an artifact object"];
    }
    if (typeof expectedKind !== "string" || !artifactSchemaPaths[expectedKind]) {
        return [`$.kind: unsupported artifact kind ${JSON.stringify(expectedKind)}`];
    }
    if (artifact.kind !== expectedKind) {
        return [`$.kind: expected ${JSON.stringify(expectedKind)}, got ${JSON.stringify(artifact.kind)}`];
    }
    return validateSchema(artifact, schemaForArtifact(expectedKind));
}

export function firstArtifactError(artifact, expectedKind) {
    return validateArtifact(artifact, expectedKind)[0] ?? null;
}

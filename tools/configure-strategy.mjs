#!/usr/bin/env node
// Configures exactly one catalogued integration on one already created vault.
//
// Usage:
//   node tools/configure-strategy.mjs --config <strategy.json> --vault <address>
//                                     --rpc-url <fork-url> [--dry-run] [--json]
//
// Exit codes: 0 configured (or planned with --dry-run), 1 refused, 2 bad
// arguments or an unreadable file.
//
// It only runs against a local development fork: every step is sent by an
// impersonated operator, which a real endpoint does not allow. Nothing here
// signs or broadcasts anything, and it configures no protocol other than the one
// named by `catalogId`.

import { existsSync, readFileSync } from "node:fs";
import { relative, resolve } from "node:path";
import { ChainError, cast, checksum, rpc } from "./lib/chain.mjs";
import { validateSchema } from "./lib/json-schema.mjs";

const repoRoot = resolve(import.meta.dirname, "..");
const schemaPath = resolve(repoRoot, "config/strategies/strategy-configuration.schema.json");
const catalogPath = resolve(repoRoot, "catalog/fuses.json");

const roles = { OWNER_ROLE: 1, ATOMIST_ROLE: 100, ALPHA_ROLE: 200, FUSE_MANAGER_ROLE: 300 };

function die(code, message) {
    console.error(`vault:configure: ${code}: ${message}`);
    process.exit(code === "INVALID_ARGUMENT" || code.endsWith("_UNREADABLE") ? 2 : 1);
}

function readJson(path, code) {
    try {
        return JSON.parse(readFileSync(path, "utf8"));
    } catch (error) {
        die(code, `cannot read ${path}: ${error.message}`);
    }
}

function parseArgs(argv) {
    const values = {};
    const rest = [];
    for (const arg of argv) {
        if (arg === "--dry-run" || arg === "--json") values[arg] = true;
        else rest.push(arg);
    }
    for (let index = 0; index < rest.length; index += 2) {
        const flag = rest[index];
        const value = rest[index + 1];
        if (!value || !["--config", "--vault", "--rpc-url"].includes(flag)) {
            die("INVALID_ARGUMENT", "expected --config <file> --vault <address> --rpc-url <url> [--dry-run] [--json]");
        }
        if (Object.hasOwn(values, flag)) die("INVALID_ARGUMENT", `duplicate ${flag}`);
        values[flag] = value;
    }
    for (const flag of ["--config", "--vault", "--rpc-url"]) {
        if (!values[flag]) die("INVALID_ARGUMENT", `missing ${flag}`);
    }
    if (!/^0x[0-9a-fA-F]{40}$/.test(values["--vault"])) die("INVALID_ARGUMENT", "--vault must be a 20-byte address");
    return {
        configPath: resolve(values["--config"]),
        vault: values["--vault"],
        rpcUrl: values["--rpc-url"],
        dryRun: values["--dry-run"] === true,
        asJson: values["--json"] === true,
    };
}

const input = parseArgs(process.argv.slice(2));
const config = readJson(input.configPath, "CONFIG_UNREADABLE");
const schema = readJson(schemaPath, "SCHEMA_UNREADABLE");
const schemaErrors = validateSchema(config, schema);
if (schemaErrors.length > 0) die("INVALID_CONFIG", `${relative(repoRoot, input.configPath)} ${schemaErrors[0]}`);

const catalog = readJson(catalogPath, "CATALOG_UNREADABLE");
const integration = catalog.integrations.find((entry) => entry.id === config.catalogId);
if (!integration) die("UNKNOWN_INTEGRATION", `the catalog has no integration "${config.catalogId}"`);
if (integration.chainId !== config.chainId) {
    die("CHAIN_MISMATCH", `integration is for chain ${integration.chainId}, config says ${config.chainId}`);
}
if (integration.market.id !== config.market.id) {
    die("MARKET_MISMATCH", `integration is market ${integration.market.id}, config says ${config.market.id}`);
}
for (const [key, contract] of Object.entries(integration.deployments)) {
    if (contract.status !== "observed") {
        die("UNVERIFIED_FUSE", `the catalog's ${key} for "${config.catalogId}" is "${contract.status}", not observed on chain`);
    }
}

const actionFuse = integration.deployments.actionFuse.address;
const balanceFuse = integration.deployments.balanceFuse.address;

const call = (address, signature, args = []) =>
    cast(["call", "--rpc-url", input.rpcUrl, address, signature, ...args.map(String)]).trim();

const send = (from, address, signature, args = []) => {
    const output = cast([
        "send",
        "--rpc-url",
        input.rpcUrl,
        "--unlocked",
        "--from",
        from,
        address,
        signature,
        ...args.map(String),
        "--json",
    ]);
    const receipt = JSON.parse(output);
    if (receipt.status !== "0x1") throw new ChainError("STEP_REVERTED", `${signature} sent by ${from} reverted`);
    return { gasUsed: Number.parseInt(receipt.gasUsed, 16), hash: receipt.transactionHash };
};

const report = await (async () => {
    const chain = await rpc(input.rpcUrl, "eth_chainId", []);
    if (chain.error) throw new ChainError("RPC_UNAVAILABLE", "the endpoint did not answer");
    if (Number.parseInt(chain.result, 16) !== config.chainId) {
        throw new ChainError("CHAIN_MISMATCH", `the endpoint serves chain ${Number.parseInt(chain.result, 16)}`);
    }
    // Impersonation is what makes this a development fork rather than a network.
    const impersonation = await rpc(input.rpcUrl, "anvil_impersonateAccount", [config.operators.owner]);
    if (impersonation.error) {
        throw new ChainError("NOT_A_FORK", "the endpoint does not support impersonation; use a local fork");
    }

    const accessManager = checksum(call(input.vault, "getAccessManagerAddress()(address)"));
    const priceManager = checksum(call(input.vault, "getPriceOracleMiddleware()(address)"));
    const vaultAsset = checksum(call(input.vault, "asset()(address)"));

    // Every substrate must be an ERC4626 vault denominated in the vault's own
    // asset; otherwise the supply fuse could never move funds into it.
    for (const substrate of config.market.substrates) {
        if (call(substrate.address, "asset()(address)") === "") {
            throw new ChainError("SUBSTRATE_NOT_ERC4626", `${substrate.address} does not answer asset()`);
        }
        const asset = checksum(call(substrate.address, "asset()(address)"));
        if (asset.toLowerCase() !== vaultAsset.toLowerCase()) {
            throw new ChainError(
                "SUBSTRATE_ASSET_MISMATCH",
                `${substrate.address} holds ${asset}, the vault's asset is ${vaultAsset}`,
            );
        }
    }

    // The balance fuse prices these; without a source the market's value is unknown.
    for (const asset of config.pricedAssets) {
        try {
            call(priceManager, "getAssetPrice(address)(uint256,uint256)", [asset]);
        } catch {
            throw new ChainError("PRICE_SOURCE_MISSING", `the vault's price manager cannot price ${asset}`);
        }
    }

    const hasRole = (role, account) => call(accessManager, "hasRole(uint64,address)(bool,uint32)", [role, account]).split("\n")[0].trim() === "true";

    const steps = [
        {
            id: "grant-roles",
            operator: config.operators.owner,
            requiredRole: "OWNER_ROLE",
            description: "grant ATOMIST_ROLE, FUSE_MANAGER_ROLE and ALPHA_ROLE to the configured operators",
            actions: [
                { signature: "grantRole(uint64,address,uint32)", target: accessManager, args: [roles.ATOMIST_ROLE, config.operators.atomist, 0] },
                { signature: "grantRole(uint64,address,uint32)", target: accessManager, args: [roles.FUSE_MANAGER_ROLE, config.operators.fuseManager, 0] },
                { signature: "grantRole(uint64,address,uint32)", target: accessManager, args: [roles.ALPHA_ROLE, config.operators.alpha, 0] },
            ],
        },
        {
            id: "register-fuses",
            operator: config.operators.fuseManager,
            requiredRole: "FUSE_MANAGER_ROLE",
            description: "register the action fuse and the market's balance fuse",
            actions: [
                { signature: "addFuses(address[])", target: input.vault, args: [`[${actionFuse}]`] },
                { signature: "addBalanceFuse(uint256,address)", target: input.vault, args: [config.market.id, balanceFuse] },
            ],
        },
        {
            id: "grant-substrates",
            operator: config.operators.fuseManager,
            requiredRole: "FUSE_MANAGER_ROLE",
            description: "allow the market to use exactly the configured ERC4626 vaults",
            actions: [
                {
                    signature: "grantMarketSubstrates(uint256,bytes32[])",
                    target: input.vault,
                    args: [
                        config.market.id,
                        `[${config.market.substrates.map((substrate) => `0x${"0".repeat(24)}${substrate.address.slice(2).toLowerCase()}`).join(",")}]`,
                    ],
                },
            ],
        },
        {
            id: "set-limits",
            operator: config.operators.atomist,
            requiredRole: "ATOMIST_ROLE",
            // The limit is a WAD fraction of the vault's total assets: 1e18 is 100%.
            description: "cap the market's share of the vault and activate the limits",
            actions: [
                {
                    signature: "setupMarketsLimits((uint256,uint256)[])",
                    target: input.vault,
                    args: [`[(${config.market.id},${config.market.limitInPercentageWad})]`],
                },
                { signature: "activateMarketsLimits()", target: input.vault, args: [] },
            ],
        },
    ];

    const executed = [];
    for (const step of steps) {
        // The first step is what creates the other roles, so it is the only one
        // whose role must already be held.
        if (step.id !== "grant-roles" && !input.dryRun && !hasRole(roles[step.requiredRole], step.operator)) {
            throw new ChainError(
                "MISSING_ROLE",
                `${step.operator} does not hold ${step.requiredRole} (${roles[step.requiredRole]}), required for step "${step.id}"`,
            );
        }
        if (step.id === "grant-roles" && !hasRole(roles.OWNER_ROLE, config.operators.owner)) {
            throw new ChainError(
                "MISSING_ROLE",
                `${config.operators.owner} does not hold OWNER_ROLE (1), required for step "grant-roles"`,
            );
        }

        const performed = [];
        for (const action of step.actions) {
            const calldata = cast(["calldata", action.signature, ...action.args.map(String)]);
            if (input.dryRun) {
                performed.push({ signature: action.signature, target: checksum(action.target), calldata, sent: false });
            } else {
                const receipt = send(step.operator, action.target, action.signature, action.args);
                performed.push({
                    signature: action.signature,
                    target: checksum(action.target),
                    calldata,
                    sent: true,
                    gasUsed: receipt.gasUsed,
                });
            }
        }
        executed.push({ ...step, operator: checksum(step.operator), actions: performed });
    }

    // Read the configuration back; a step that "succeeded" but changed nothing is not a pass.
    const verification = input.dryRun
        ? null
        : (() => {
              const fuses = call(input.vault, "getFuses()(address[])").toLowerCase();
              const substrates = call(input.vault, "getMarketSubstrates(uint256)(bytes32[])", [config.market.id]).toLowerCase();
              const limit = call(input.vault, "getMarketLimit(uint256)(uint256)", [config.market.id]).split(" ")[0];
              const checks = [
                  { id: "fuse.registered", ok: fuses.includes(actionFuse.toLowerCase()), detail: fuses },
                  {
                      id: "substrates.granted",
                      ok: config.market.substrates.every((substrate) => substrates.includes(substrate.address.slice(2).toLowerCase())),
                      detail: substrates,
                  },
                  { id: "market.limit", ok: limit === config.market.limitInPercentageWad, detail: limit },
                  { id: "roles.alpha", ok: hasRole(roles.ALPHA_ROLE, config.operators.alpha), detail: config.operators.alpha },
              ];
              return { ok: checks.every((check) => check.ok), checks };
          })();

    if (verification && !verification.ok) {
        throw new ChainError(
            "CONFIGURATION_NOT_APPLIED",
            `the steps ran but the vault does not report the configuration: ${verification.checks
                .filter((check) => !check.ok)
                .map((check) => check.id)
                .join(", ")}`,
        );
    }

    return {
        schemaVersion: 1,
        status: input.dryRun ? "planned" : "configured",
        kind: "strategy-configuration",
        chainId: config.chainId,
        catalogId: config.catalogId,
        vault: checksum(input.vault),
        accessManager,
        priceManager,
        market: { id: config.market.id, limitInPercentageWad: config.market.limitInPercentageWad },
        fuses: { action: checksum(actionFuse), balance: checksum(balanceFuse) },
        steps: executed,
        verification,
        warnings: [
            "this configures only the catalogued integration; other protocols need their own catalog entry and their own run",
            "operators are impersonated on a development fork; on a network each step is a transaction signed by the role holder",
        ],
    };
})().catch((error) => {
    if (!(error instanceof ChainError)) throw error;
    die(error.code, error.message);
});

if (input.asJson) {
    process.stdout.write(`${JSON.stringify(report, null, 4)}\n`);
} else {
    console.log(`vault:configure: ${report.status} ${report.vault} (${report.catalogId})`);
    for (const step of report.steps) {
        console.log(`  ${step.id.padEnd(16)} as ${step.operator} (${step.requiredRole}) — ${step.actions.length} call(s)`);
    }
    if (report.verification) {
        for (const check of report.verification.checks) console.log(`  ${check.ok ? "ok  " : "FAIL"} ${check.id}`);
    }
}
process.exit(0);

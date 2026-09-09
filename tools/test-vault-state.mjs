import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { test } from "node:test";
import { checkVaultState } from "./lib/vault-state.mjs";

const repoRoot = resolve(import.meta.dirname, "..");
// Real readings of a vault created through the unchanged Ethereum pilot factory,
// captured with vault:simulate on the pinned fork block.
const fixture = JSON.parse(readFileSync(resolve(repoRoot, "test/fixtures/vault-state/created-vault.json"), "utf8"));

const clone = (value) => JSON.parse(JSON.stringify(value));

function verify({ readings = fixture.readings, expected = fixture.expected, instance = fixture.instance } = {}) {
    return checkVaultState(clone(readings), clone(expected), clone(instance));
}

function failed(result) {
    return result.checks.filter((check) => !check.ok).map((check) => check.id);
}

test("a correctly created vault passes every check", () => {
    const result = verify();
    assert.equal(result.ok, true, `unexpected failures: ${failed(result).join(", ")}`);
    assert.ok(result.checks.length >= 25, `only ${result.checks.length} checks ran`);
});

for (const scenario of [
    {
        name: "a component address with no code",
        mutate: (state) => (state.readings.components.withdrawManager.codeChars = 2),
        expectFailures: ["component.withdrawManager.code"],
    },
    {
        name: "a zero component address",
        mutate: (state) => {
            state.readings.components.priceManager.address = "0x0000000000000000000000000000000000000000";
        },
        expectFailures: ["component.priceManager.code"],
    },
    {
        name: "a vault holding another asset",
        mutate: (state) => (state.readings.vault.asset = "0xdAC17F958D2ee523a2206206994597C13D831ec7"),
        expectFailures: ["vault.asset"],
    },
    {
        name: "another name than the one requested",
        mutate: (state) => (state.expected.name = "Some Other Vault"),
        expectFailures: ["vault.name"],
    },
    {
        name: "the vault pointing at a foreign access manager",
        mutate: (state) => (state.readings.vault.accessManager = "0x1111111111111111111111111111111111111111"),
        expectFailures: ["vault.accessManager"],
    },
    {
        name: "the vault pointing at a foreign price manager",
        mutate: (state) => (state.readings.vault.priceOracleMiddleware = "0x1111111111111111111111111111111111111111"),
        expectFailures: ["vault.priceOracleMiddleware"],
    },
    {
        name: "a vault base the factory does not report",
        mutate: (state) => (state.readings.factory.plasmaVaultBase = "0x1111111111111111111111111111111111111111"),
        expectFailures: ["vault.plasmaVaultBase"],
    },
    {
        name: "an owner without OWNER_ROLE",
        mutate: (state) => (state.readings.access.ownerHasRole = false),
        expectFailures: ["access.owner"],
    },
    {
        name: "an owner whose role carries an execution delay",
        mutate: (state) => (state.readings.access.ownerExecutionDelay = "86400"),
        expectFailures: ["access.ownerDelay"],
    },
    {
        name: "a redemption delay other than the requested one",
        mutate: (state) => (state.expected.redemptionDelaySeconds = "7200"),
        expectFailures: ["access.redemptionDelay"],
    },
    {
        name: "a withdraw manager belonging to another vault",
        mutate: (state) => (state.readings.withdraw.plasmaVault = "0x1111111111111111111111111111111111111111"),
        expectFailures: ["withdraw.plasmaVault"],
    },
    {
        name: "a withdraw window that is not the factory's",
        mutate: (state) => (state.readings.withdraw.windowSeconds = "1"),
        expectFailures: ["withdraw.window"],
    },
    {
        name: "a fee manager belonging to another vault",
        mutate: (state) => (state.readings.fees.plasmaVault = "0x1111111111111111111111111111111111111111"),
        expectFailures: ["fees.feeManagerVault"],
    },
    {
        name: "a DAO management fee other than the expected package's",
        mutate: (state) => (state.expected.managementFeeBps = 30),
        expectFailures: ["fees.daoManagement"],
    },
    {
        name: "a DAO performance fee other than the expected package's",
        mutate: (state) => (state.readings.fees.daoPerformanceFee = "200"),
        expectFailures: ["fees.daoPerformance"],
    },
    {
        name: "fees paid to another recipient",
        mutate: (state) => (state.readings.fees.daoFeeRecipient = "0x1111111111111111111111111111111111111111"),
        expectFailures: ["fees.daoRecipient"],
    },
    {
        name: "a vault paying management fees somewhere else",
        mutate: (state) => (state.readings.vault.managementFeeAccount = "0x1111111111111111111111111111111111111111"),
        expectFailures: ["fees.vaultManagementAccount"],
    },
    {
        name: "a vault charging a management rate the fee manager does not know",
        mutate: (state) => (state.readings.vault.managementFeeInPercentage = "999"),
        expectFailures: ["fees.vaultManagementRate"],
    },
    {
        name: "underlying decimals other than the declared ones",
        mutate: (state) => (state.expected.underlyingDecimals = "18"),
        expectFailures: ["underlying.decimals"],
    },
]) {
    test(`rejects ${scenario.name}`, () => {
        const state = {
            readings: clone(fixture.readings),
            expected: clone(fixture.expected),
            instance: clone(fixture.instance),
        };
        scenario.mutate(state);
        const result = checkVaultState(state.readings, state.expected, state.instance);
        assert.equal(result.ok, false, "the verifier accepted a state it should reject");
        assert.deepEqual(failed(result), scenario.expectFailures);
    });
}

test("existing addresses alone are not accepted as proof", () => {
    // Every component exists and has code, but nothing is wired to anything.
    const state = {
        readings: clone(fixture.readings),
        expected: clone(fixture.expected),
        instance: clone(fixture.instance),
    };
    state.readings.vault.accessManager = "0x1111111111111111111111111111111111111111";
    state.readings.vault.priceOracleMiddleware = "0x1111111111111111111111111111111111111111";
    state.readings.vault.rewardsClaimManager = "0x1111111111111111111111111111111111111111";
    state.readings.withdraw.plasmaVault = "0x1111111111111111111111111111111111111111";
    state.readings.fees.plasmaVault = "0x1111111111111111111111111111111111111111";

    const result = checkVaultState(state.readings, state.expected, state.instance);
    assert.equal(result.ok, false);
    assert.ok(
        result.checks.filter((check) => check.id.startsWith("component.")).every((check) => check.ok),
        "the component existence checks were expected to still pass",
    );
    assert.deepEqual(failed(result), [
        "vault.accessManager",
        "vault.priceOracleMiddleware",
        "vault.rewardsClaimManager",
        "withdraw.plasmaVault",
        "fees.feeManagerVault",
    ]);
});
